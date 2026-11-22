import Foundation

/// Abstraction used by AppState (mockable in tests).
public protocol TerminalControlling: AnyObject, Sendable {
    /// Bring the session's terminal to front. Returns true if some bridge acknowledged.
    func focus(session: ClaudeSession) async -> Bool
    /// Type `text` + Enter into the session's terminal.
    func send(session: ClaudeSession, text: String) async -> Bool
    /// Bring Claude Desktop to the front (Claude Desktop sessions). There is no documented deep
    /// link to a specific Code session, so this only activates the app.
    func activateClaudeDesktop(session: ClaudeSession) async -> Bool
}

public extension TerminalControlling {
    /// Host-aware focus (what AppState calls): Claude Desktop sessions activate Claude Desktop and
    /// never touch the editor sockets; terminal sessions use `focus(session:)`.
    func show(session: ClaudeSession) async -> Bool {
        switch session.host {
        case .claudeDesktop: return await activateClaudeDesktop(session: session)
        case .terminal: return await focus(session: session)
        }
    }
}

/// Focuses / types into a session's terminal:
/// - Terminal and iTerm2 (found in the claude process's parent chain): AppleScript addressed by
///   the session's tty (`NativeTerminal`), then `open -b` brings the app forward.
/// - Everything else: the VS Code-family companion extension over
///   ~/Library/Application Support/Turnipot/vscode-<editor>-<pid>.sock (newline JSON,
///   BridgeRequest -> BridgeResponse). When no extension answers, focus still brings forward the
///   app the session runs in (Ghostty, Warp, an editor without the extension, …).
public final class TerminalBridge: TerminalControlling, @unchecked Sendable {
    public typealias Locator = @Sendable (_ pid: Int32) -> NativeTerminal.Location?
    public typealias ScriptRunner = @Sendable (_ script: String, _ arguments: [String]) -> NativeTerminal.ScriptResult
    public typealias Opener = @Sendable (_ openArguments: [String]) -> Void

    public let runtimeDir: URL
    /// Activates Claude Desktop (injectable so tests never launch it).
    let desktopActivator: @Sendable () -> Void
    /// Sessions whose terminal may be showing a Claude dialog (kept in sync by AppState):
    /// `send` refuses them, since the reply's Enter would pick the dialog's highlighted option.
    public let sendGate: TerminalSendGate
    /// Where a claude pid's terminal lives (injectable: tests never inspect real processes).
    let locator: Locator
    /// Runs AppleScript for Terminal / iTerm2 (injectable: tests never run osascript).
    let scriptRunner: ScriptRunner
    /// `/usr/bin/open <args>` (injectable: tests never activate apps).
    let opener: Opener

    public init(runtimeDir: URL = NotchPaths.runtimeDir,
                sendGate: TerminalSendGate = TerminalSendGate(),
                desktopActivator: @escaping @Sendable () -> Void = { TerminalBridge.activateClaudeDesktopApp() },
                locator: @escaping Locator = { NativeTerminal.locate(pid: $0) },
                scriptRunner: @escaping ScriptRunner = { NativeTerminal.runScript($0, arguments: $1) },
                opener: @escaping Opener = { TerminalBridge.runOpen($0) }) {
        self.runtimeDir = runtimeDir
        self.sendGate = sendGate
        self.desktopActivator = desktopActivator
        self.locator = locator
        self.scriptRunner = scriptRunner
        self.opener = opener
    }

    /// Terminal / iTerm2: select the session's tab and raise its window, then activate the app
    /// (also when the script can't run, e.g. Automation permission denied: the app still comes
    /// forward). Otherwise sends {"type":"focus","shellPid":N} to each editor window's socket
    /// until one owns the terminal and activates that editor; with no answer, activates the app
    /// found in the parent chain. Returns false only when nothing could be brought forward.
    public func focus(session: ClaudeSession) async -> Bool {
        // Claude Desktop sessions have no terminal (shellPid is its `disclaimer` helper).
        if session.host == .claudeDesktop { return await activateClaudeDesktop(session: session) }
        let location = await offMain { [locator] in locator(session.pid) }
        if let location, let terminal = location.terminal {
            if let tty = location.tty {
                let script = terminal.focusScript()
                _ = await offMain { [scriptRunner] in scriptRunner(script, [tty]) }
            }
            await offMain { [opener] in opener(["-b", terminal.bundleId]) }
            return true
        }
        if let shellPid = session.shellPid, let r = await broadcastResponse(.focus(shellPid: shellPid)) {
            // Only an editor that answered gets activated, so nothing is ever cold-launched.
            // Older extension builds don't report appPath: they only ran in VSCodium.
            let opener = self.opener
            await offMain { Self.activateEditor(appPath: r.appPath, opener: opener) }
            return true
        }
        guard let location else { return false }
        await offMain { [opener] in opener(["-a", location.appPath]) }
        return true
    }

    /// Terminal / iTerm2: types the reply as a bracketed paste plus Return (AppleScript).
    /// Otherwise sends {"type":"send","shellPid":N,"text":...} to each editor socket until ok.
    /// Not possible for Claude Desktop sessions (returns false without touching anything).
    public func send(session: ClaudeSession, text: String) async -> Bool {
        guard session.host == .terminal else { return false }
        guard !sendGate.isBlocked(session.sessionId) else { return false }
        guard let shellPid = session.shellPid else { return false }
        // Only type into the terminal while claude owns it: after ^Z (or once claude has exited)
        // the shell has the terminal and the reply + Enter would run as a shell command.
        guard let job = Self.jobState(pid: session.pid),
              Self.isForegroundJob(pgid: job.pgid, tpgid: job.tpgid, stopped: job.stopped) else { return false }
        let location = await offMain { [locator] in locator(session.pid) }
        if let location, let terminal = location.terminal {
            guard let tty = location.tty else { return false }
            let script = terminal.sendScript(reply: text)
            return await offMain { [scriptRunner] in scriptRunner(script, [tty]) } == .ok
        }
        return await broadcast(.send(shellPid: shellPid, text: text))
    }

    /// Runs blocking work (sysctl walks, osascript, open) off the caller's executor.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }

    /// True unless the process is stopped or another process group (e.g. the shell after ^Z) is
    /// the foreground group of its terminal. Unknown terminal (tpgid <= 0): true.
    public static func isForegroundJob(pgid: Int32, tpgid: Int32, stopped: Bool) -> Bool {
        if stopped { return false }
        if tpgid <= 0 { return true }
        return pgid == tpgid
    }

    /// Process group, its terminal's foreground process group and whether it is stopped
    /// (sysctl KERN_PROC_PID). nil if the process doesn't exist.
    public static func jobState(pid: Int32) -> (pgid: Int32, tpgid: Int32, stopped: Bool)? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return (info.kp_eproc.e_pgid, info.kp_eproc.e_tpgid, info.kp_proc.p_stat == SSTOP)
    }

    /// `/usr/bin/open -b com.anthropic.claudefordesktop`.
    public func activateClaudeDesktop(session: ClaudeSession) async -> Bool {
        let activate = desktopActivator
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                activate()
                cont.resume(returning: true)
            }
        }
    }

    /// All vscode-*.sock files in runtimeDir.
    public func socketURLs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDir.path)) ?? []
        return names
            .filter { $0.hasPrefix(NotchPaths.vscodeSocketPrefix) && $0.hasSuffix(NotchPaths.vscodeSocketSuffix) }
            .sorted()
            .map { runtimeDir.appendingPathComponent($0) }
    }

    /// Try every socket; remove sockets whose connect() fails with ECONNREFUSED/ENOENT (stale).
    /// Per-socket timeout ~1.5s. Returns true on first {"ok":true}.
    public func broadcast(_ request: BridgeRequest) async -> Bool {
        await broadcastResponse(request) != nil
    }

    /// Like `broadcast`, returning the first ok response (nil if none).
    public func broadcastResponse(_ request: BridgeRequest) async -> BridgeResponse? {
        let urls = socketURLs()
        guard !urls.isEmpty else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<BridgeResponse?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                for url in urls {
                    switch Self.exchange(socketPath: url.path, request: request, timeout: 1.5) {
                    case .response(let r) where r.ok:
                        cont.resume(returning: r)
                        return
                    case .stale:
                        try? FileManager.default.removeItem(at: url)
                    default:
                        continue
                    }
                }
                cont.resume(returning: nil)
            }
        }
    }

    /// Connect to a Unix socket, write one JSON line, read one JSON line. nil on any failure.
    public static func roundTrip(socketPath: String, request: BridgeRequest, timeout: TimeInterval = 1.5) -> BridgeResponse? {
        if case .response(let r) = exchange(socketPath: socketPath, request: request, timeout: timeout) { return r }
        return nil
    }

    /// Bring the editor app to the front: `/usr/bin/open -a <appPath>` (or `-b com.vscodium` when
    /// the extension didn't say). `open` is a plain CLI, so no Dock icon flashes; keeps NotchCore
    /// free of AppKit.
    public static func activateEditor(appPath: String?, opener: Opener = { runOpen($0) }) {
        if let appPath, appPath.hasSuffix(".app"), FileManager.default.fileExists(atPath: appPath) {
            opener(["-a", appPath])
        } else {
            opener(["-b", NotchConstants.vscodiumBundleId])
        }
    }

    /// Bring Claude Desktop to the front: `/usr/bin/open -b com.anthropic.claudefordesktop`
    /// (mirrors activateEditor; no AppKit in NotchCore).
    public static func activateClaudeDesktopApp() {
        runOpen(["-b", NotchConstants.claudeDesktopBundleId])
    }

    public static func runOpen(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            // best effort
        }
    }

    // MARK: - Internals

    enum ExchangeResult {
        case response(BridgeResponse)
        case stale            // nobody listening: ECONNREFUSED / ENOENT
        case failed           // timeout, bad reply, other error
    }

    static func exchange(socketPath: String, request: BridgeRequest, timeout: TimeInterval) -> ExchangeResult {
        guard var payload = try? JSONEncoder().encode(request) else { return .failed }
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed }
        defer { close(fd) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard var addr = UnixSocket.address(path: socketPath) else { return .failed }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let e = errno
            return (e == ECONNREFUSED || e == ENOENT) ? .stale : .failed
        }
        guard UnixSocket.writeAll(fd: fd, data: payload) else { return .failed }
        guard let line = UnixSocket.readLine(fd: fd, maxBytes: 64 * 1024),
              let resp = try? JSONDecoder().decode(BridgeResponse.self, from: line) else { return .failed }
        return .response(resp)
    }
}

/// Small POSIX helpers shared by TerminalBridge and HookServer.
enum UnixSocket {
    /// sun_path is 104 bytes on Darwin (incl. NUL).
    static func address(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func writeAll(fd: Int32, data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return true }
            while offset < buf.count {
                let n = write(fd, base + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    /// Reads until "\n" (excluded) or EOF. Returns nil on error/timeout/empty/oversize.
    static func readLine(fd: Int32, maxBytes: Int) -> Data? {
        var result = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                result.append(contentsOf: buf[0..<nl])
                return result
            }
            result.append(contentsOf: buf[0..<n])
            if result.count > maxBytes { return nil }
        }
        return result.isEmpty ? nil : result
    }
}
