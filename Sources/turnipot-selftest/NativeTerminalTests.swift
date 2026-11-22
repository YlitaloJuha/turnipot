import Foundation
import NotchCore

/// Terminal / iTerm2 support: locating the host app, the reply payload, the scripts, and how
/// TerminalBridge routes focus / send (with injected locator, script runner and opener).
func registerNativeTerminalTests() {
    // MARK: host app from the parent chain
    expectEqual(NativeTerminal.hostAppPath(ancestorPaths: ["/bin/zsh", "/usr/bin/login",
                                                           "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]),
                "/System/Applications/Utilities/Terminal.app", "native: Terminal via login")
    expectEqual(NativeTerminal.hostAppPath(ancestorPaths: ["/bin/zsh",
                                                           "/Applications/VSCodium.app/Contents/Frameworks/VSCodium Helper.app/Contents/MacOS/VSCodium Helper"]),
                "/Applications/VSCodium.app", "native: editor helper resolves to the editor")
    expectEqual(NativeTerminal.hostAppPath(ancestorPaths: ["/bin/zsh", "/opt/homebrew/bin/tmux"]), nil, "native: tmux server has no app")
    expectEqual(NativeTerminal(bundleId: "com.apple.Terminal"), .appleTerminal, "native: Terminal bundle id")
    expectEqual(NativeTerminal(bundleId: "com.googlecode.iTerm2"), .iTerm2, "native: iTerm2 bundle id, case-insensitive")
    expectEqual(NativeTerminal(bundleId: "com.mitchellh.ghostty"), nil, "native: Ghostty is activate-only")
    expectEqual(NativeTerminal(bundleId: nil), nil, "native: unknown bundle")
    check("native: tty of bogus pid nil", NativeTerminal.ttyPath(pid: 99_999_999) == nil)
    if isatty(0) != 0, let mine = ttyname(0) {
        expectEqual(NativeTerminal.ttyPath(pid: getpid()), String(cString: mine), "native: own tty")
    }

    // MARK: reply payload
    expectEqual(NativeTerminal.sanitizedReply("a\nb\r\nc\rd"), "a b c d", "native: newlines become spaces")
    expectEqual(NativeTerminal.sanitizedReply("x\u{1B}[201~y\u{07}z\u{7F}"), "x[201~yz", "native: control characters dropped")
    expectEqual(NativeTerminal.sanitizedReply("héllo ✓ 🌱"), "héllo ✓ 🌱", "native: unicode kept")
    expectEqual(NativeTerminal.replyPayload("hi"), "\u{1B}[200~hi\u{1B}[201~\r", "native: bracketed paste + Return")

    // MARK: scripts
    for t in NativeTerminal.allCases {
        check("native: \(t) focus script targets its app", t.focusScript().contains("application id \"\(t.bundleId)\""))
        check("native: \(t) send script targets its app", t.sendScript(reply: "x").contains("application id \"\(t.bundleId)\""))
        check("native: \(t) scripts match by tty", t.focusScript().contains("tty of") && t.sendScript(reply: "x").contains("tty of"))
        check("native: \(t) reply embedded as a literal", t.sendScript(reply: "say \"hi\"").contains(#""say \"hi\"""#))
    }
    expectEqual(NativeTerminal.appleScriptLiteral(#"a\b "c""#), #""a\\b \"c\"""#, "native: literal escapes backslash and quote")
    expectEqual(NativeTerminal.appleScriptLiteral("x\ny\u{1B}"), #""x y""#, "native: literal is sanitized")
    check("native: iTerm2 sends without its own newline, Return explicit",
          NativeTerminal.iTerm2.sendScript(reply: "x").contains("newline no") && NativeTerminal.iTerm2.sendScript(reply: "x").contains("character id 13"))
    check("native: Terminal leaves the Return to do script",
          !NativeTerminal.appleTerminal.sendScript(reply: "x").contains("character id 13"))
    expectEqual(NativeTerminal.parseResult(status: 0, stdout: "ok", stderr: ""), .ok, "native: ok")
    expectEqual(NativeTerminal.parseResult(status: 0, stdout: "missing", stderr: ""), .missing, "native: missing")
    expectEqual(NativeTerminal.parseResult(status: 1, stdout: "",
                                           stderr: "execution error: Not authorized to send Apple events to Terminal. (-1743)"),
                .notAuthorized, "native: Automation denied")

    // MARK: TerminalBridge routing
    let rt = URL(fileURLWithPath: "/tmp/notch-native-\(getpid())", isDirectory: true)   // no sockets in it
    let log = CallLog()
    func bridge(_ location: NativeTerminal.Location?, result: NativeTerminal.ScriptResult = .ok) -> TerminalBridge {
        TerminalBridge(runtimeDir: rt, desktopActivator: { log.add("desktop") },
                       locator: { _ in location },
                       scriptRunner: { script, args in
                           let reply = script.range(of: "[200~\" & ").map { r in String(script[r.upperBound...].prefix { $0 != "\n" }) } ?? ""
                           log.add("script:\(script.contains("do script") || script.contains("write text") ? "send:\(reply)" : "focus"):\(args.joined(separator: "|"))")
                           return result },
                       opener: { log.add("open:\($0.joined(separator: " "))") })
    }
    func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached { result = await body(); sem.signal() }
        sem.wait()
        return result!
    }
    let now = Date()
    // getpid(): a live process that is its terminal's foreground job, so send's job check passes.
    let me = ClaudeSession(pid: getpid(), shellPid: getppid(), sessionId: "N", cwd: "/x", name: "n",
                           status: .idle, startedAt: now, updatedAt: now)
    let terminalApp = NativeTerminal.Location(appPath: "/System/Applications/Utilities/Terminal.app",
                                              bundleId: "com.apple.Terminal", tty: "/dev/ttys042")

    let tb = bridge(terminalApp)
    check("bridge native: Terminal focus ok", run { await tb.focus(session: me) })
    expectEqual(log.take(), ["script:focus:/dev/ttys042", "open:-b com.apple.Terminal"], "bridge native: select tab, then activate")
    check("bridge native: Terminal send ok", run { await tb.send(session: me, text: "go on\nplease") })
    expectEqual(log.take(), [#"script:send:"go on please" & (character id 27) & "[201~":/dev/ttys042"#], "bridge native: reply in the script, tty as argument")

    let denied = bridge(terminalApp, result: .notAuthorized)
    check("bridge native: focus still activates when Automation is denied", run { await denied.focus(session: me) })
    expectEqual(log.take(), ["script:focus:/dev/ttys042", "open:-b com.apple.Terminal"], "bridge native: denied -> app still activated")
    check("bridge native: send fails when Automation is denied", !run { await denied.send(session: me, text: "hi") })
    _ = log.take()

    var noTty = terminalApp; noTty.tty = nil
    let nt = bridge(noTty)
    check("bridge native: no tty -> focus activates the app", run { await nt.focus(session: me) })
    expectEqual(log.take(), ["open:-b com.apple.Terminal"], "bridge native: no tty -> no script")
    check("bridge native: no tty -> no send", !run { await nt.send(session: me, text: "hi") })
    expectEqual(log.take(), [], "bridge native: no tty -> nothing typed")

    let ghostty = bridge(NativeTerminal.Location(appPath: "/Applications/Ghostty.app", bundleId: "com.mitchellh.ghostty", tty: "/dev/ttys043"))
    check("bridge native: other app -> focus activates it", run { await ghostty.focus(session: me) })
    expectEqual(log.take(), ["open:-a /Applications/Ghostty.app"], "bridge native: other app activated, no script")
    check("bridge native: other app -> no quick reply", !run { await ghostty.send(session: me, text: "hi") })
    expectEqual(log.take(), [], "bridge native: other app -> nothing typed")

    let nowhere = bridge(nil)
    check("bridge native: no app and no extension -> focus fails", !run { await nowhere.focus(session: me) })
    expectEqual(log.take(), [], "bridge native: nothing activated")

    let gate = TerminalSendGate(); gate.setBlocked(["N"])
    let gated = TerminalBridge(runtimeDir: rt, sendGate: gate, desktopActivator: {}, locator: { _ in terminalApp },
                               scriptRunner: { _, _ in log.add("script"); return .ok }, opener: { _ in })
    check("bridge native: dialog flag refuses the reply", !run { await gated.send(session: me, text: "1") })
    expectEqual(log.take(), [], "bridge native: flagged session never scripted")

    // MARK: opt-in end-to-end run against a real tab (types into it!):
    //   TURNIPOT_E2E_TTY=/dev/ttys005 TURNIPOT_E2E_APP=com.apple.Terminal TURNIPOT_E2E_TEXT="say hi" swift run turnipot-selftest
    let env = ProcessInfo.processInfo.environment
    if let tty = env["TURNIPOT_E2E_TTY"], let app = NativeTerminal(bundleId: env["TURNIPOT_E2E_APP"] ?? "com.apple.Terminal") {
        expectEqual(NativeTerminal.runScript(app.focusScript(), arguments: [tty]), .ok, "e2e: focus \(app) \(tty)")
        if let text = env["TURNIPOT_E2E_TEXT"] {
            expectEqual(NativeTerminal.runScript(app.sendScript(reply: text), arguments: [tty]), .ok,
                        "e2e: send to \(app) \(tty)")
        }
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func take() -> [String] { lock.lock(); defer { items = []; lock.unlock() }; return items }
}
