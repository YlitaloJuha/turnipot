import AppKit
import ServiceManagement
import NotchCore

/// Bundle facts used by setup and the update check.
enum AppInfo {
    /// CFBundleShortVersionString (nil when not running from Turnipot.app, e.g. `swift run`).
    static var version: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    static var bundlePath: String { Bundle.main.bundleURL.path }
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    /// Launched from a quarantined download: macOS runs it from a random read-only copy.
    static var isTranslocated: Bool { bundlePath.contains("/AppTranslocation/") }
    /// In /Applications or ~/Applications (a stable place for the hook path and the login item).
    static var isInApplications: Bool {
        let parent = (bundlePath as NSString).deletingLastPathComponent
        return parent == "/Applications" || parent == NSHomeDirectory() + "/Applications"
    }
    /// The hook binary inside this bundle.
    static var hookPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/turnipot-hook").path }
    static var vsixPath: String? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent(EditorExtensions.vsixResourceName).path }
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Launch at login

/// "Launch at login" via SMAppService.mainApp (macOS 13+). Registers this app bundle as it is now,
/// so it belongs in /Applications (see scripts/install-app.sh).
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()
    @Published private(set) var status: SMAppService.Status = .notRegistered

    private init() { refresh() }

    func refresh() {
        guard AppInfo.isAppBundle else { return }
        let s = SMAppService.mainApp.status
        if s != status { status = s }
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    var statusName: String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    var menuTitle: String {
        status == .requiresApproval ? "Launch at login (approve in System Settings…)" : "Launch at login"
    }

    func toggle(ui: NotchUIState) {
        refresh()
        guard AppInfo.isAppBundle else {
            ui.confirm("Launch at login needs Turnipot.app", detail: "Build it with scripts/build-app.sh", tone: .bad, duration: 3)
            return
        }
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            explainApproval(ui: ui)
            return
        }
        do {
            if status == .enabled {
                try SMAppService.mainApp.unregister()
                refresh()
                ui.confirm("Turnipot won't launch at login", tone: .neutral, duration: 1.6)
            } else {
                try SMAppService.mainApp.register()
                refresh()
                if status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    explainApproval(ui: ui)
                } else if AppInfo.isInApplications {
                    ui.confirm("✓ Turnipot launches at login", tone: .ok, duration: 1.6)
                } else {
                    ui.prompt("✓ Turnipot launches at login",
                              detail: "From \(AppInfo.abbreviate(AppInfo.bundlePath))",
                              lines: ["Move it to /Applications (scripts/install-app.sh) so the login item keeps working,",
                                      "then turn this off and on again."],
                              tone: .ok, actions: [.init(title: "OK", role: .primary)], duration: 12)
                }
            }
        } catch {
            refresh()
            ui.confirm("Couldn't change the login item", detail: error.localizedDescription, tone: .bad, duration: 4)
        }
    }

    private func explainApproval(ui: NotchUIState) {
        ui.prompt("Approve Turnipot in Login Items",
                  detail: "System Settings › General › Login Items",
                  lines: ["macOS asks you to allow it once: turn Turnipot on under \"Open at Login\"."],
                  tone: .neutral,
                  actions: [.init(title: "Open Login Items", role: .primary) { SMAppService.openSystemSettingsLoginItems() },
                            .init(title: "OK")],
                  duration: 20)
    }
}

// MARK: - Update check

/// On launch and every 24 h: one anonymous GET of the latest GitHub release (no auth, no
/// cookies, User-Agent "Turnipot/<version>"), compared with the bundle version. Silent on any
/// error (a private repo answers 404). Off with ⚙ → Check for updates.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isEnabled: Bool
    /// Shows the one-time "Turnipot vX is available" drop-down (set by AppDelegate).
    var notify: ((ReleaseInfo) -> Bool)?

    private var lastCheck: Date?
    private var timer: Timer?
    private var inFlight = false
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [UpdateCheck.enabledKey: true])
        isEnabled = defaults.bool(forKey: UpdateCheck.enabledKey)
    }

    func start() {
        timer?.invalidate()
        // Hourly tick: checks when 24 h have passed (survives sleep), retries a held-back notice.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        defaults.set(on, forKey: UpdateCheck.enabledKey)
        if on { lastCheck = nil; tick() } else { available = nil }
    }

    func openReleasePage() {
        NSWorkspace.shared.open(available?.pageURL ?? UpdateCheck.releasesPageURL)
    }

    private func tick() {
        guard isEnabled, let version = AppInfo.version else { return }
        if let r = available { maybeNotify(r) }
        guard !inFlight, UpdateCheck.isDue(lastCheck: lastCheck, now: Date()) else { return }
        inFlight = true
        lastCheck = Date()
        Task { [weak self] in
            let result = await Self.fetch(version: version)
            guard let self else { return }
            self.inFlight = false
            guard self.isEnabled else { return }
            self.available = result
            if let result { self.maybeNotify(result) }
        }
    }

    private func maybeNotify(_ r: ReleaseInfo) {
        guard UpdateCheck.shouldNotify(r, notifiedVersion: defaults.string(forKey: UpdateCheck.notifiedVersionKey)),
              notify?(r) == true else { return }
        defaults.set(r.version.description, forKey: UpdateCheck.notifiedVersionKey)
    }

    nonisolated private static func fetch(version: String) async -> ReleaseInfo? {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = UpdateCheck.timeout
        config.timeoutIntervalForResource = UpdateCheck.timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: UpdateCheck.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: UpdateCheck.timeout)
        req.setValue(UpdateCheck.userAgent(version: version), forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return nil }
        return UpdateCheck.evaluate(status: http.statusCode, body: data, current: version)
    }
}

// MARK: - Install the hook / the editor extension from the app

@MainActor
enum SetupActions {
    static var settingsPath: String { NSHomeDirectory() + "/.claude/settings.json" }

    /// Prompts need the island to themselves (the reader would only show their title).
    private static func makeRoom(_ appState: AppState) {
        if appState.readerSessionId != nil { appState.closeReader() }
    }

    // MARK: Hook

    static func installHook(appState: AppState, ui: NotchUIState) {
        makeRoom(appState)
        let hook = AppInfo.hookPath
        guard AppInfo.isAppBundle, FileManager.default.isExecutableFile(atPath: hook) else {
            ui.confirm("No hook in this build", detail: "Build Turnipot.app with scripts/build-app.sh", tone: .bad, duration: 3)
            return
        }
        if AppInfo.isTranslocated {
            ui.prompt("Move Turnipot to Applications first",
                      detail: "macOS is running it from a temporary copy",
                      lines: ["The hook must point at a stable path. Drag Turnipot.app into /Applications,",
                              "open it from there, then choose Install Claude Code hook… again."],
                      tone: .bad, actions: [.init(title: "OK", role: .primary)], duration: 30)
            return
        }
        let text = FileManager.default.contents(atPath: settingsPath).map { String(decoding: $0, as: UTF8.self) }
        let plan: HookSettings.Plan
        do { plan = try HookSettings.plan(settingsText: text, hookPath: hook) } catch {
            ui.confirm("Can't edit ~/.claude/settings.json", detail: "\(error)", tone: .bad, duration: 5)
            return
        }
        if !plan.changes {
            ui.prompt("The Claude Code hook is installed",
                      detail: AppInfo.abbreviate(hook),
                      lines: ["Registered in ~/.claude/settings.json as a PermissionRequest hook."],
                      tone: .ok,
                      actions: [.init(title: "Remove…", role: .destructive) { confirmRemoveHook(appState: appState, ui: ui) },
                                .init(title: "OK", role: .primary)],
                      duration: 30)
            return
        }
        var lines = ["Adds a PermissionRequest hook to ~/.claude/settings.json (a backup is saved first):",
                     "   " + AppInfo.abbreviate(hook)]
        if plan.removed > 0 {
            let old = plan.existingCommands.count == 1 ? ": " + AppInfo.abbreviate(plan.existingCommands[0]) : ""
            lines.append("Replaces \(plan.removed == 1 ? "the earlier Turnipot hook" : "\(plan.removed) earlier Turnipot hooks")\(old)")
        }
        if !plan.otherCommands.isEmpty {
            lines.append("Keeps \(plan.otherCommands.count) other PermissionRequest hook\(plan.otherCommands.count == 1 ? "" : "s") and everything else.")
        }
        if !AppInfo.isInApplications {
            lines.append("Turnipot isn't in /Applications: moving the app later breaks the hook (install it again then).")
        }
        ui.prompt("Install the Claude Code hook?",
                  detail: "Answer permissions, questions and plans from the notch",
                  lines: lines, tone: .neutral,
                  actions: [.init(title: "Cancel"),
                            .init(title: "Install", role: .primary) { applyHook(hook, ui: ui) }])
    }

    private static func confirmRemoveHook(appState: AppState, ui: NotchUIState) {
        ui.prompt("Remove the Claude Code hook?",
                  detail: "Permission prompts go back to the terminal only",
                  lines: ["Removes Turnipot's PermissionRequest entries from ~/.claude/settings.json",
                          "(a backup is saved first; other hooks stay)."],
                  tone: .neutral,
                  actions: [.init(title: "Cancel"),
                            .init(title: "Remove", role: .destructive) { applyHook(nil, ui: ui) }])
    }

    private static func applyHook(_ hook: String?, ui: NotchUIState) {
        do {
            let r = try HookSettings.apply(settingsPath: settingsPath, hookPath: hook)
            let backup = r.backupPath.map { "Backup: " + AppInfo.abbreviate($0) }
            if hook == nil {
                ui.confirm(r.wrote ? "✓ Hook removed" : "No Turnipot hook was installed", detail: backup, tone: .ok, duration: 3)
            } else {
                ui.prompt("✓ Claude Code hook installed",
                          detail: "New sessions use it; running ones after /hooks or a restart",
                          lines: backup.map { [$0] } ?? [],
                          tone: .ok, actions: [.init(title: "OK", role: .primary)], duration: 8)
            }
        } catch {
            ui.confirm("Couldn't update settings.json", detail: "\(error)", tone: .bad, duration: 5)
        }
    }

    // MARK: Editor extension

    static func installExtension(appState: AppState, ui: NotchUIState) {
        makeRoom(appState)
        guard let vsix = AppInfo.vsixPath, FileManager.default.fileExists(atPath: vsix) else {
            ui.confirm("No extension in this build", detail: "Use scripts/install-extension.sh", tone: .bad, duration: 3)
            return
        }
        let found = EditorExtensions.detect()
        let withCli = found.filter { $0.cli != nil }
        let names = withCli.map(\.editor.appName).joined(separator: ", ")
        guard !withCli.isEmpty else {
            let noCli = found.map(\.editor.appName)
            ui.confirm(noCli.isEmpty ? "No VSCodium, VS Code or Cursor found" : "Can't reach \(noCli.joined(separator: ", "))'s command line tool",
                       detail: noCli.isEmpty ? nil : "Use scripts/install-extension.sh --copy", tone: .bad, duration: 4)
            return
        }
        var lines = ["Installs the Turnipot Bridge into \(names) with their command line tools.",
                     "It lets Turnipot focus a session's terminal and type quick replies into it."]
        let skipped = found.filter { $0.cli == nil }.map(\.editor.appName)
        if !skipped.isEmpty { lines.append("Skips \(skipped.joined(separator: ", ")) (no command line tool found).") }
        lines.append("Reload the editor windows afterwards.")
        ui.prompt("Install the editor extension?", detail: names, lines: lines, tone: .neutral,
                  actions: [.init(title: "Cancel"),
                            .init(title: "Install", role: .primary) { runExtensionInstall(vsix: vsix, found: withCli, ui: ui) }])
    }

    private static func runExtensionInstall(vsix: String, found: [EditorExtensions.Found], ui: NotchUIState) {
        ui.confirm("Installing the editor extension…", tone: .neutral, duration: 120)
        Task.detached {
            let outcomes = EditorExtensions.install(vsix: vsix, into: found)
            await MainActor.run {
                let ok = outcomes.filter(\.ok).map(\.editor.appName)
                let failed = outcomes.filter { !$0.ok }
                var lines: [String] = []
                if !ok.isEmpty { lines.append("Reload their windows: ⌘⇧P › Developer: Reload Window") }
                for f in failed { lines.append("\(f.editor.appName): \(f.message.isEmpty ? "failed" : f.message)") }
                ui.prompt(ok.isEmpty ? "Couldn't install the editor extension" : "✓ Installed into \(ok.joined(separator: ", "))",
                          lines: lines, tone: ok.isEmpty ? .bad : .ok,
                          actions: [.init(title: "OK", role: .primary)], duration: 15)
            }
        }
    }
}
