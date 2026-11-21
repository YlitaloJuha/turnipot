import Foundation

/// Polls `claude -p "/usage"` every NotchConstants.usagePollInterval seconds and pushes
/// UsageSnapshot into AppState. On failure keeps last windows and calls markUsageStale().
/// Never reads keychain tokens or calls private endpoints.
@MainActor
public final class UsageMonitor {
    public let appState: AppState
    public let interval: TimeInterval

    private var loopTask: Task<Void, Never>?
    private var inFlight = false
    /// Last error (for diagnostics / UI tooltips).
    public private(set) var lastError: Error?

    public init(appState: AppState, interval: TimeInterval = NotchConstants.usagePollInterval) {
        self.appState = appState
        self.interval = interval
    }

    /// Immediate fetch, then every `interval`.
    public func start() {
        stop()
        let interval = max(10, interval)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Fetch once now; updates AppState (success -> updateUsage(stale:false), failure -> markUsageStale()).
    public func refreshNow() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            // locateClaudeBinary may spawn a login shell (up to 8s): never on the main thread.
            let located = await Task.detached(priority: .utility) { Self.locateClaudeBinary() }.value
            guard let binary = located else { throw UsageError.binaryNotFound }
            let output = try await Self.runUsageCommand(binary: binary)
            let windows = Self.parse(output)
            guard !windows.isEmpty else { throw UsageError.noWindowsParsed }
            lastError = nil
            appState.updateUsage(UsageSnapshot(windows: windows, fetchedAt: Date(), stale: false))
        } catch {
            lastError = error
            if case UsageError.binaryNotFound = error { Self.resetBinaryCache() }
            appState.markUsageStale()
        }
    }

    // MARK: Helpers (nonisolated, unit-testable)

    /// Parse every line matching "Current <label>: <n>% used · resets <text>" (also tolerate
    /// "-" instead of "·", and missing " · resets ..." part -> resetsText ""). Label is kept
    /// verbatim, e.g. "session", "week (all models)", "week (Fable)". Order preserved.
    public nonisolated static func parse(_ output: String) -> [UsageWindow] {
        let cleaned = stripANSI(output)
        var windows: [UsageWindow] = []
        var seen = Set<String>()
        for rawLine in cleaned.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let m = lineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let labelR = Range(m.range(at: 1), in: line),
                  let pctR = Range(m.range(at: 2), in: line) else { continue }
            let label = line[labelR].trimmingCharacters(in: .whitespaces)
            guard let pct = Double(line[pctR]) else { continue }
            var resets = ""
            if m.range(at: 3).location != NSNotFound, let r = Range(m.range(at: 3), in: line) {
                resets = line[r].trimmingCharacters(in: .whitespaces)
            }
            guard !label.isEmpty, !seen.contains(label) else { continue }
            seen.insert(label)
            windows.append(UsageWindow(label: label, percent: Int(pct.rounded()), resetsText: resets))
        }
        return windows
    }

    /// "Current <label>: <n>% used [· resets <text>]"; separator may be "·", "-", "–", "—" or "|".
    private nonisolated static let lineRegex: NSRegularExpression = {
        let pattern = #"^Current\s+(.+?)\s*:\s*(\d+(?:\.\d+)?)\s*%\s*used(?:\s*[·\-–—|•,]?\s*resets?\s*(.*))?\s*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private nonisolated static let ansiRegex = try! NSRegularExpression(
        pattern: #"\u001B\[[0-9;?]*[ -/]*[@-~]|\u001B\][^\u0007]*\u0007"#)

    nonisolated static func stripANSI(_ s: String) -> String {
        ansiRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    // MARK: Binary lookup

    private nonisolated static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedBinary: String?

    nonisolated static func resetBinaryCache() {
        cacheLock.lock(); cachedBinary = nil; cacheLock.unlock()
    }

    /// Resolve the claude binary once via `/bin/zsh -lc 'command -v claude'` (cache it);
    /// fall back to ~/.local/bin/claude, /opt/homebrew/bin/claude, /usr/local/bin/claude.
    public nonisolated static func locateClaudeBinary() -> String? {
        cacheLock.lock()
        if let c = cachedBinary, FileManager.default.isExecutableFile(atPath: c) {
            cacheLock.unlock(); return c
        }
        cacheLock.unlock()

        var found: String?
        if let out = runSync("/bin/zsh", ["-lc", "command -v claude"], timeout: 8) {
            // Login shells may print banners; take the last absolute path line.
            let candidate = out.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.hasPrefix("/") }
            if let candidate, FileManager.default.isExecutableFile(atPath: candidate) { found = candidate }
        }
        if found == nil {
            let home = NotchPaths.home.path
            found = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        cacheLock.lock(); cachedBinary = found; cacheLock.unlock()
        return found
    }

    /// Run a short command synchronously and return stdout (nil on failure/timeout).
    private nonisolated static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Run `<binary> -p "/usage"` with a 20s timeout, cwd = home, stdin = /dev/null; return stdout.
    public nonisolated static func runUsageCommand(binary: String, timeout: TimeInterval = 20) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-p", "/usage"]
        p.currentDirectoryURL = NotchPaths.home
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; make sure the binary's own dir and common dirs are present.
        let extra = [(binary as NSString).deletingLastPathComponent, "\(NotchPaths.home.path)/.local/bin",
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        env["NO_COLOR"] = "1"
        // If the app was started from inside a Claude Code terminal, don't make the child think
        // it is nested in that session.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env[key] = nil }
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var out = Data(), err = Data()
            var finished = false
        }
        let box = Box()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let group = DispatchGroup()
            group.enter()
            p.terminationHandler = { _ in group.leave() }
            do {
                try p.run()
            } catch {
                // Nothing was launched (and our copies of the pipes' write ends are still open, so
                // readers started earlier would block forever): just report the error.
                cont.resume(throwing: error)
                return
            }
            group.enter(); group.enter()
            DispatchQueue.global(qos: .utility).async {
                let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                box.lock.lock(); box.out = d; box.lock.unlock(); group.leave()
            }
            DispatchQueue.global(qos: .utility).async {
                let d = errPipe.fileHandleForReading.readDataToEndOfFile()
                box.lock.lock(); box.err = d; box.lock.unlock(); group.leave()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.lock.lock()
                let alreadyDone = box.finished
                box.finished = true
                box.lock.unlock()
                guard !alreadyDone else { return }
                if p.isRunning {
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    }
                }
                // Resume even if a grandchild still holds the pipes open.
                cont.resume(throwing: UsageError.timedOut)
            }
            group.notify(queue: .global(qos: .utility)) {
                box.lock.lock()
                let alreadyDone = box.finished
                box.finished = true
                let out = String(decoding: box.out, as: UTF8.self)
                let err = String(decoding: box.err, as: UTF8.self)
                box.lock.unlock()
                guard !alreadyDone else { return }
                if p.terminationStatus != 0 {
                    cont.resume(throwing: UsageError.nonZeroExit(p.terminationStatus,
                                                                 String((err.isEmpty ? out : err).prefix(500))))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }

    public enum UsageError: Error {
        case notImplemented
        case binaryNotFound
        case timedOut
        case nonZeroExit(Int32, String)
        case noWindowsParsed
    }
}
