import AppKit
import NotchCore

/// Wires AppState + monitors + servers + window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let terminalBridge = TerminalBridge()
    lazy var appState: AppState = {
        let s = AppState(terminal: terminalBridge)
        s.sendGate = terminalBridge.sendGate
        return s
    }()
    var sessionMonitor: SessionMonitor?
    var usageMonitor: UsageMonitor?
    var hookServer: HookServer?
    var awayMonitor: AwayMonitor?
    var windowController: NotchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = appState
        if let demo = DemoMode.requestedState {
            DemoMode.apply(demo, to: state)
            windowController = NotchWindowController(appState: state)
            windowController?.show()
            return
        }
        LegacyMigration.runAtLaunch()
        NotchPaths.ensureRuntimeDir()

        let server = HookServer { req in await state.handleHookRequest(req) }
        do {
            try server.start()
        } catch HookServer.ServerError.alreadyRunning {
            NSLog("Turnipot: another instance is already running; exiting")
            NSApp.terminate(nil)
            return
        } catch {
            NSLog("Turnipot: hook server failed: \(error)")
        }
        hookServer = server

        sessionMonitor = SessionMonitor(appState: state)
        sessionMonitor?.start()

        usageMonitor = UsageMonitor(appState: state)
        usageMonitor?.start()

        awayMonitor = AwayMonitor(appState: state)
        awayMonitor?.start()

        windowController = NotchWindowController(appState: state)
        windowController?.show()

        // Update check (one anonymous request on launch and every 24 h; ⚙ → Check for updates).
        let updates = UpdateChecker.shared
        updates.notify = { [weak self] release in
            // One-time notice; held back while away or while something else needs the island.
            guard let ui = self?.windowController?.ui, state.awaySince == nil,
                  state.pendingPermissions.isEmpty, ui.confirmation == nil else { return false }
            ui.prompt("Turnipot v\(release.version) is available",
                      detail: "You have v\(AppInfo.version ?? "?") · also in ⚙ → Update available",
                      tone: .neutral,
                      actions: [.init(title: "Later"),
                                .init(title: "Download", role: .primary) { updates.openReleasePage() }],
                      duration: 15)
            return true
        }
        updates.start()
    }

    private var terminationPending = false

    /// Quit (menu, SIGTERM/SIGINT via main.swift): retract the island back into the notch first,
    /// then let termination continue. A safety timeout guarantees we never hang on quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let wc = windowController, wc.panel != nil, !terminationPending else { return .terminateNow }
        terminationPending = true
        var replied = false
        let reply: @MainActor () -> Void = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        wc.retract { reply() }
        // Safety net (common-modes timer: fires in the modal run loop while termination is pending).
        NotchWindowController.runLoopAfter(1.0) { reply() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.tearDown()
        appState.cancelAllPermissions()
        hookServer?.stop()
        sessionMonitor?.stop()
        usageMonitor?.stop()
        awayMonitor?.stop()
    }
}
