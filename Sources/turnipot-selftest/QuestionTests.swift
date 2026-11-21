import Foundation
import NotchCore
import HookOutput

// AskUserQuestion / ExitPlanMode answered from the notch: parsing, answers -> app.sock response ->
// hook stdout (exactly as documented at https://code.claude.com/docs/en/hooks), fallbacks.
func registerQuestionTests() {
    func json(_ s: String) -> JSONValue { (try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))) ?? .null }
    func dict(_ s: String) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]) ?? [:] }
    /// App decision -> JSON line on app.sock -> what turnipot-hook prints.
    func hookOutput(_ d: PermissionDecision, tool: String) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(d.hookResponse),
              let wire = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return HookOutput.output(response: wire, toolName: tool)
    }
    func same(_ a: [String: Any]?, _ expected: String, _ name: String) {
        guard let a else { check(name + " (nil output)", false); return }
        let ok = NSDictionary(dictionary: a).isEqual(to: dict(expected))
        if !ok { print("  got:      \(HookOutput.serialize(a) ?? "?")\n  expected: \(expected)") }
        check(name, ok)
    }

    // Real-shaped input (from a transcript on this machine; field order as Claude sends it).
    let single = json(#"{"questions":[{"question":"Now that the StartFaultReset gap is confirmed reachable, what next?","header":"Next step","multiSelect":false,"options":[{"label":"Fix it now","description":"Add the same rollback."},{"label":"Retry the interrupted subagent","description":"Get the third data point."},{"label":"Stop here","description":"Leave the bug for later."}]}]}"#)
    let qs = AskQuestion.parse(single)
    expectEqual(qs?.count, 1, "question: parse count")
    expectEqual(qs?.first?.header, "Next step", "question: header")
    expectEqual(qs?.first?.options.map(\.label), ["Fix it now", "Retry the interrupted subagent", "Stop here"], "question: labels")
    expectEqual(qs?.first?.options.first?.description, "Add the same rollback.", "question: description")
    expectEqual(qs?.first?.multiSelect, false, "question: multiSelect")
    check("question: malformed -> nil", AskQuestion.parse(json(#"{"questions":[]}"#)) == nil)
    check("question: no text -> nil", AskQuestion.parse(json(#"{"questions":[{"header":"x","options":[]}]}"#)) == nil)
    check("question: missing -> nil", AskQuestion.parse(json(#"{"foo":1}"#)) == nil)
    check("question: duplicate texts -> nil",
          AskQuestion.parse(json(#"{"questions":[{"question":"A?","options":[]},{"question":"A?","options":[]}]}"#)) == nil)
    expectEqual(AskQuestion.parse(json(#"{"questions":[{"question":"Q?","options":[{"label":"a"}]}]}"#))?.first?.multiSelect, false,
                "question: multiSelect defaults to false")

    // Selection rules.
    var sel = QuestionSelection()
    sel.toggle(0, multiSelect: false); sel.toggle(2, multiSelect: false)
    expectEqual(sel.options, [2], "selection: single-select replaces")
    sel.toggle(2, multiSelect: false)
    check("selection: single-select toggles off", !sel.isAnswered)
    var multi = QuestionSelection()
    multi.toggle(2, multiSelect: true); multi.toggle(0, multiSelect: true)
    expectEqual(multi.options, [0, 2], "selection: multi-select accumulates")
    check("selection: blank other is unanswered", !QuestionSelection(other: "   ").isAnswered)

    // Single question -> hook output (docs example shape: questions echoed + answers).
    let q0 = qs![0]
    let a1 = QuestionAnswers.answers(qs!, [QuestionSelection(options: [1])])
    expectEqual(a1, [q0.question: "Retry the interrupted subagent"], "answers: single")
    let upd1 = QuestionAnswers.updatedInput(original: single, answers: a1!)
    same(hookOutput(.answer(updatedInput: upd1), tool: "AskUserQuestion"), ##"""
    {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{
      "questions":[{"question":"Now that the StartFaultReset gap is confirmed reachable, what next?","header":"Next step","multiSelect":false,"options":[{"label":"Fix it now","description":"Add the same rollback."},{"label":"Retry the interrupted subagent","description":"Get the third data point."},{"label":"Stop here","description":"Leave the bug for later."}]}],
      "answers":{"Now that the StartFaultReset gap is confirmed reachable, what next?":"Retry the interrupted subagent"}}}}}
    """##, "hook output: single-select answer")

    // Two questions, second multi-select + Other text.
    let two = json(#"{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false},{"question":"Which extras?","header":"Extras","options":[{"label":"CSV","description":""},{"label":"Clear","description":""},{"label":"Pause","description":""}],"multiSelect":true}]}"#)
    let tq = AskQuestion.parse(two)!
    expectEqual(tq.map(\.multiSelect), [false, true], "question: 2 parsed, second multi")
    check("answers: incomplete -> nil", QuestionAnswers.answers(tq, [QuestionSelection(options: [0]), QuestionSelection()]) == nil)
    let a2 = QuestionAnswers.answers(tq, [QuestionSelection(options: [0]),
                                          QuestionSelection(options: [2, 0], other: " Mark the start ")])
    expectEqual(a2, ["Which framework?": "React", "Which extras?": "CSV, Pause, Mark the start"],
                "answers: multi-select joined with \", \" in option order + other text")
    same(hookOutput(.answer(updatedInput: QuestionAnswers.updatedInput(original: two, answers: a2!)), tool: "AskUserQuestion"), ##"""
    {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedInput":{
      "questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false},{"question":"Which extras?","header":"Extras","options":[{"label":"CSV","description":""},{"label":"Clear","description":""},{"label":"Pause","description":""}],"multiSelect":true}],
      "answers":{"Which framework?":"React","Which extras?":"CSV, Pause, Mark the start"}}}}}
    """##, "hook output: two questions, multi-select + other")
    // Single-select "Other…" text replaces the option.
    expectEqual(QuestionAnswers.answer(for: tq[0], QuestionSelection(options: [1], other: "Svelte")), "Svelte",
                "answers: single-select other text wins")

    // ExitPlanMode.
    let planInput = json(##"{"plan":"# Refactor auth\n1. Extract middleware","planFilePath":"/Users/x/.claude/plans/refactor-auth.md"}"##)
    let plan = PlanContent.parse(planInput)
    expectEqual(plan?.plan, "# Refactor auth\n1. Extract middleware", "plan: text")
    expectEqual(plan?.filePath, "/Users/x/.claude/plans/refactor-auth.md", "plan: file path")
    expectEqual(plan?.title, "Refactor auth", "plan: title from heading")
    check("plan: empty -> nil", PlanContent.parse(json(#"{"plan":"  "}"#)) == nil)
    check("plan: literal empty model input -> nil", PlanContent.parse(json("{}")) == nil)
    same(hookOutput(.approvePlan(updatedInput: planInput, mode: .manual), tool: "ExitPlanMode"), ##"""
    {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow",
      "updatedInput":{"plan":"# Refactor auth\n1. Extract middleware","planFilePath":"/Users/x/.claude/plans/refactor-auth.md"},
      "updatedPermissions":[{"type":"setMode","mode":"default","destination":"session"}]}}}
    """##, "hook output: plan approve (ask before edits)")
    same(hookOutput(.approvePlan(updatedInput: planInput, mode: .acceptEdits), tool: "ExitPlanMode"), ##"""
    {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow",
      "updatedInput":{"plan":"# Refactor auth\n1. Extract middleware","planFilePath":"/Users/x/.claude/plans/refactor-auth.md"},
      "updatedPermissions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}}
    """##, "hook output: plan approve + acceptEdits")
    expectEqual(PlanApprovalMode.auto.rawValue, "auto", "plan: auto mode value")
    let fb = PlanContent.feedbackMessage("Use a toggle")
    check("plan: feedback message carries the text", fb.hasSuffix("The user said:\nUse a toggle"))
    same(hookOutput(.denyWithMessage(fb), tool: "ExitPlanMode"),
         #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"\#(fb.replacingOccurrences(of: "\n", with: "\\n"))"}}}"#,
         "hook output: keep planning -> deny + message")

    // Fallbacks: no output => Claude Code shows its own prompt.
    check("fallback: ask -> no output", hookOutput(.ask, tool: "AskUserQuestion") == nil)
    check("fallback: plain allow for AskUserQuestion -> no output (docs: allow alone not sufficient)",
          hookOutput(.allow, tool: "AskUserQuestion") == nil)
    check("fallback: plain allow for ExitPlanMode -> no output", hookOutput(.allow, tool: "ExitPlanMode") == nil)
    check("fallback: malformed response -> no output", HookOutput.output(response: ["nope": 1], toolName: "AskUserQuestion") == nil)
    check("fallback: unknown decision -> no output", HookOutput.output(response: ["decision": "maybe"], toolName: "Bash") == nil)
    check("hook: invalid mode ignored", HookOutput.serialize(HookOutput.output(response: ["decision": "allow", "updatedInput": [:], "mode": "yolo"],
                                                                               toolName: "ExitPlanMode") ?? [:])?.contains("setMode") == false)
    // Existing permission outputs unchanged.
    same(hookOutput(.allowAlways(rule: "Bash(npm test:*)"), tool: "Bash"), ##"""
    {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}}}
    """##, "hook output: always allow unchanged")
    same(hookOutput(.deny, tool: "Bash"), #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user denied this tool call from Turnipot."}}}"#,
         "hook output: deny unchanged")
    // Request types / waits.
    expectEqual(HookOutput.requestType(toolName: "AskUserQuestion"), "question", "hook: question type")
    expectEqual(HookOutput.requestType(toolName: "ExitPlanMode"), "plan", "hook: plan type")
    expectEqual(HookOutput.requestType(toolName: "Bash"), "permission", "hook: permission type")
    expectEqual(HookOutput.waitSeconds(requestType: "permission", environment: [:]), 60, "hook: permission wait")
    expectEqual(HookOutput.waitSeconds(requestType: "question", environment: [:]), 570, "hook: question wait")
    check("app gives up before the hook (question)", NotchConstants.questionUITimeout < 570)
    check("hook waits less than the installed timeout (600)", HookOutput.waitSeconds(requestType: "plan", environment: [:]) < 600)
    expectEqual(RequestKind(toolName: "ExitPlanMode").uiTimeout, NotchConstants.questionUITimeout, "kind: plan timeout")
    expectEqual(RequestKind(toolName: "Bash").uiTimeout, NotchConstants.permissionUITimeout, "kind: permission timeout")

    // AppState: questions share the permission queue; malformed ones go straight back to the terminal.
    MainActor.assumeIsolated {
        let app = AppState()
        let qReq = HookRequest(type: "question", sessionId: "s1", cwd: "/tmp", toolName: "AskUserQuestion",
                               toolInput: single, hookInput: .object(["tool_input": single]))
        var got: HookResponse?
        let t = Task { @MainActor in got = await app.handleHookRequest(qReq) }
        _ = t
        // Let the task enqueue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expectEqual(app.pendingPermissions.first?.kind, .question, "app: question queued")
        check("app: needs-you mood for a question", app.mascotMood == .shake)
        if let id = app.pendingPermissions.first?.id {
            app.resolvePermission(id: id, decision: .answer(updatedInput: upd1))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expectEqual(got?.decision, "allow", "app: answer -> allow")
        expectEqual(got?.updatedInput, upd1, "app: answer carries updatedInput")

        var bad: HookResponse?
        let bReq = HookRequest(type: "question", sessionId: "s1", cwd: nil, toolName: "AskUserQuestion",
                               toolInput: json("{}"), hookInput: .null)
        Task { @MainActor in bad = await app.handleHookRequest(bReq) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expectEqual(bad?.decision, "ask", "app: malformed question -> ask (terminal)")
        check("app: malformed question not queued", app.pendingPermissions.isEmpty)

        var oldest: [String] = []
        let p1 = PermissionRequest(sessionId: "a", toolName: "Bash", summary: "ls", toolInput: .null, raw: .null)
        let p2 = PermissionRequest(sessionId: "b", toolName: "ExitPlanMode", summary: "", toolInput: planInput, raw: .null)
        app.enqueuePermission(p1) { _ in oldest.append("p1") }
        app.enqueuePermission(p2) { _ in oldest.append("p2") }
        expectEqual(app.currentPermission?.id, p1.id, "app: oldest first across kinds")
        app.resolvePermission(id: p1.id, decision: .allow)
        expectEqual(app.currentPermission?.kind, .plan, "app: plan next")
        app.resolvePermission(id: p2.id, decision: .ask)
        expectEqual(oldest, ["p1", "p2"], "app: both answered")
    }

    registerHookBinaryTests()
}

/// Runs the built turnipot-hook binary against a fake app socket (skipped if it isn't built:
/// `swift build` first). Checks stdout for a real answer, and the fail-open paths.
private func registerHookBinaryTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bin = [".build/debug/turnipot-hook", ".build/release/turnipot-hook"].map { root.appendingPathComponent($0).path }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    guard let bin else { print("skip: turnipot-hook binary not built"); return }

    let input = #"{"session_id":"s","cwd":"/tmp","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}]}}"#

    /// One-shot fake app: accepts one connection, checks the request type, replies `reply` after `delay` (nil = never).
    func run(reply: String?, delay: Double = 0, env extra: [String: String] = [:], socket: Bool = true) -> (out: String, type: String?, seconds: Double) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cn-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.sock").path
        var seenType: String?
        let lock = NSLock()
        var listenFD: Int32 = -1
        if socket {
            listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            listen(listenFD, 4)
            let fd = listenFD
            Thread.detachNewThread {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 65536); var got = Data()
                while !got.contains(0x0A) {
                    let n = read(c, &buf, buf.count); if n <= 0 { break }; got.append(contentsOf: buf[0..<n])
                }
                if let o = (try? JSONSerialization.jsonObject(with: got.split(separator: 0x0A).first ?? Data())) as? [String: Any] {
                    lock.lock(); seenType = o["type"] as? String; lock.unlock()
                }
                if let reply {
                    Thread.sleep(forTimeInterval: delay)
                    _ = (reply + "\n").withCString { write(c, $0, strlen($0)) }
                    Thread.sleep(forTimeInterval: 0.2)
                } else {
                    Thread.sleep(forTimeInterval: 3)
                }
                close(c)
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        var env = ProcessInfo.processInfo.environment
        env["TURNIPOT_SOCKET"] = path
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout
        let start = Date()
        try? p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if listenFD >= 0 { close(listenFD) }
        lock.lock(); let t = seenType; lock.unlock()
        return (String(decoding: data, as: UTF8.self), t, Date().timeIntervalSince(start))
    }

    let answered = run(reply: #"{"decision":"allow","updatedInput":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}],"answers":{"Which framework?":"React"}}}"#)
    expectEqual(answered.type, "question", "hook binary: sends type question")
    let expected = #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedInput":{"answers":{"Which framework?":"React"},"questions":[{"header":"Framework","multiSelect":false,"options":[{"description":"Component library","label":"React"},{"description":"Progressive framework","label":"Vue"}],"question":"Which framework?"}]}},"hookEventName":"PermissionRequest"}}"#
    expectEqual(answered.out.trimmingCharacters(in: .whitespacesAndNewlines), expected, "hook binary: prints documented answer JSON")
    expectEqual(run(reply: #"{"decision":"ask"}"#).out, "", "hook binary: ask -> no output")
    expectEqual(run(reply: "not json").out, "", "hook binary: malformed reply -> no output")
    expectEqual(run(reply: #"{"decision":"allow"}"#).out, "", "hook binary: allow without answers -> no output")
    let slow = run(reply: nil, env: ["TURNIPOT_QUESTION_TIMEOUT": "1"])
    expectEqual(slow.out, "", "hook binary: timeout -> no output")
    check("hook binary: timeout honoured (\(String(format: "%.1f", slow.seconds))s)", slow.seconds < 2.5)
    expectEqual(run(reply: nil, socket: false).out, "", "hook binary: app not running -> no output")
}
