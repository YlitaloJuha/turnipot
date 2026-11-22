import Foundation
import NotchCore

/// Records calls instead of talking to editors / Claude Desktop.
final class MockTerminal: TerminalControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func record(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }
    func focus(session: ClaudeSession) async -> Bool { record("focus:\(session.sessionId)"); return true }
    func send(session: ClaudeSession, text: String) async -> Bool { record("send:\(session.sessionId):\(text)"); return true }
    func activateClaudeDesktop(session: ClaudeSession) async -> Bool { record("desktop:\(session.sessionId)"); return true }
}

/// Session host classification (terminal vs Claude Desktop) and host-aware focus / reply.
func registerHostTests() {
    // MARK: classification
    let desktopTree = ["/Applications/Claude.app/Contents/Helpers/disclaimer",
                       "/Applications/Claude.app/Contents/MacOS/Claude", "/sbin/launchd"]
    let terminalTree = ["/bin/zsh", "/Applications/VSCodium.app/Contents/Frameworks/VSCodium Helper.app/Contents/MacOS/VSCodium Helper"]
    expectEqual(SessionHost.classify(entrypoint: "claude-desktop", ancestorPaths: []), .claudeDesktop, "host: entrypoint claude-desktop")
    expectEqual(SessionHost.classify(entrypoint: "Claude-Desktop", ancestorPaths: terminalTree), .claudeDesktop, "host: entrypoint wins, case-insensitive")
    expectEqual(SessionHost.classify(entrypoint: "cli", ancestorPaths: []), .terminal, "host: entrypoint cli")
    expectEqual(SessionHost.classify(entrypoint: "cli", ancestorPaths: desktopTree), .terminal, "host: cli entrypoint wins over tree")
    expectEqual(SessionHost.classify(entrypoint: nil, ancestorPaths: desktopTree), .claudeDesktop, "host: missing entrypoint, Claude.app parent chain")
    expectEqual(SessionHost.classify(entrypoint: "something-new", ancestorPaths: Array(desktopTree.dropFirst())), .claudeDesktop, "host: unknown entrypoint, grandparent Claude.app")
    expectEqual(SessionHost.classify(entrypoint: nil, ancestorPaths: terminalTree), .terminal, "host: missing entrypoint, terminal tree")
    expectEqual(SessionHost.classify(entrypoint: nil, ancestorPaths: []), .terminal, "host: nothing known -> terminal")
    // The claude binary bundled by Claude Desktop is a lowercase claude.app elsewhere: no match.
    let bundled = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code/2.1.0/abc/claude.app/Contents/MacOS/claude"
    expectEqual(SessionHost.classify(entrypoint: nil, ancestorPaths: [bundled, "/bin/zsh"]), .terminal, "host: bundled claude.app is not Claude Desktop")
    expectEqual(SessionHost.classify(entrypoint: nil, ancestorPaths: ["/Applications/Claude.appx/x"]), .terminal, "host: exact app path only")

    let df = SessionFile(pid: 3270, sessionId: "d", cwd: "/Users/x/Work Projects/acme-api", kind: "interactive", entrypoint: "claude-desktop")
    expectEqual(ClaudeSession(file: df, shellPid: 3269).host, .claudeDesktop, "host: ClaudeSession(file:) classifies")
    expectEqual(ClaudeSession(file: SessionFile(pid: 1, sessionId: "t", entrypoint: "cli"), shellPid: 2).host, .terminal, "host: cli session")
    expectEqual(SessionMonitor.host(of: df), .claudeDesktop, "host: monitor uses entrypoint without walking")
    // Process-tree helpers on our own process (selftest runs from a shell, not Claude Desktop).
    check("host: processPath of self", SessionMonitor.processPath(of: getpid())?.hasSuffix("turnipot-selftest") == true)
    check("host: ancestorPaths non-empty", !SessionMonitor.ancestorPaths(of: getpid()).isEmpty)
    check("host: processPath of bogus pid nil", SessionMonitor.processPath(of: 99_999_999) == nil)

    // MARK: AppState routing via the mock
    MainActor.assumeIsolated {
        let mock = MockTerminal()
        let app = AppState(terminal: mock)
        let now = Date()
        let desk = ClaudeSession(pid: 3270, shellPid: 3269, host: .claudeDesktop, sessionId: "D", cwd: "/x/acme-api",
                                 name: "acme-api", status: .idle, startedAt: now, updatedAt: now)
        let term = ClaudeSession(pid: 500, shellPid: 499, sessionId: "T", cwd: "/x/notch",
                                 name: "notch", status: .idle, startedAt: now, updatedAt: now)
        app.updateSessions([desk, term], now: now)
        app.focusSession(id: "D")
        app.focusSession(id: "T")
        app.sendReply(sessionId: "D", text: "hello")
        app.sendReply(sessionId: "T", text: "hi")
        let deadline = Date().addingTimeInterval(2)
        while mock.calls.count < 3 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let calls = mock.calls
        check("host: desktop focus activates Claude Desktop", calls.contains("desktop:D"))
        check("host: desktop focus never uses the editor focus", !calls.contains("focus:D"))
        check("host: terminal focus uses the editor", calls.contains("focus:T") && !calls.contains("desktop:T"))
        check("host: no quick reply into Claude Desktop", !calls.contains { $0.hasPrefix("send:D") })
        check("host: terminal quick reply still sent", calls.contains("send:T:hi"))
    }

    // MARK: TerminalBridge never touches editor sockets for Claude Desktop sessions
    // A real listening socket named like an editor's (never accepted, so connections queue in the
    // backlog): counting pending connections afterwards tells whether the bridge touched it.
    let rt = URL(fileURLWithPath: "/tmp/notch-host-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: rt, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rt) }
    let sockPath = rt.appendingPathComponent("vscode-1.sock").path
    let listener = listenUnix(path: sockPath)
    defer { if listener >= 0 { close(listener) } }
    check("bridge: test listener up", listener >= 0)
    let activations = Counter()
    let bridge = TerminalBridge(runtimeDir: rt, desktopActivator: { activations.bump() }, locator: { _ in nil })
    let now = Date()
    let desk = ClaudeSession(pid: 3270, shellPid: 3269, host: .claudeDesktop, sessionId: "D", cwd: "/x",
                             name: "d", status: .idle, startedAt: now, updatedAt: now)
    let term = ClaudeSession(pid: 500, shellPid: 499, sessionId: "T", cwd: "/x",
                             name: "t", status: .idle, startedAt: now, updatedAt: now)
    func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached { result = await body(); sem.signal() }
        sem.wait()
        return result!
    }
    check("bridge: desktop focus ok", run { await bridge.focus(session: desk) })
    check("bridge: desktop show ok", run { await bridge.show(session: desk) })
    expectEqual(activations.value, 2, "bridge: Claude Desktop activated (injected)")
    check("bridge: desktop send refused", !run { await bridge.send(session: desk, text: "hi") })
    expectEqual(drainPending(listener), 0, "bridge: desktop focus/send never connected to an editor socket")
    // Sanity: a terminal session does go to the sockets (nobody answers -> false after timeout).
    check("bridge: terminal focus without answer fails", !run { await bridge.focus(session: term) })
    expectEqual(drainPending(listener), 1, "bridge: terminal focus connected to the editor socket")
    expectEqual(activations.value, 2, "bridge: terminal focus never activates Claude Desktop")

    // Quick reply only while claude is the terminal's foreground job (after ^Z the shell would
    // run the reply as a command).
    check("job: foreground group", TerminalBridge.isForegroundJob(pgid: 10, tpgid: 10, stopped: false))
    check("job: shell has the terminal (^Z / exited)", !TerminalBridge.isForegroundJob(pgid: 10, tpgid: 7, stopped: false))
    check("job: stopped", !TerminalBridge.isForegroundJob(pgid: 10, tpgid: 10, stopped: true))
    check("job: no terminal info -> not blocked", TerminalBridge.isForegroundJob(pgid: 10, tpgid: 0, stopped: false))
    check("job: own process found", TerminalBridge.jobState(pid: getpid()) != nil)
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    if (try? sleeper.run()) != nil {
        kill(sleeper.processIdentifier, SIGSTOP)
        usleep(100_000)
        expectEqual(TerminalBridge.jobState(pid: sleeper.processIdentifier)?.stopped, true, "job: SIGSTOPped process is stopped")
        let stopped = ClaudeSession(pid: sleeper.processIdentifier, shellPid: 499, sessionId: "S", cwd: "/x",
                                    name: "s", status: .idle, startedAt: now, updatedAt: now)
        check("bridge: no reply into a suspended claude", !run { await bridge.send(session: stopped, text: "hi") })
        kill(sleeper.processIdentifier, SIGKILL)
        sleeper.waitUntilExit()
        check("bridge: no reply once claude has exited", !run { await bridge.send(session: stopped, text: "hi") })
        expectEqual(drainPending(listener), 0, "bridge: refused replies never reach the editor socket")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

/// Bound + listening AF_UNIX socket (never accepts on its own). -1 on failure.
private func listenUnix(path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return -1 }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0, listen(fd, 8) == 0 else { close(fd); return -1 }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    return fd
}

/// Accept (and close) every queued connection; returns how many there were.
private func drainPending(_ fd: Int32) -> Int {
    guard fd >= 0 else { return -1 }
    var n = 0
    while true {
        let c = accept(fd, nil, nil)
        if c < 0 { break }
        close(c); n += 1
    }
    return n
}
