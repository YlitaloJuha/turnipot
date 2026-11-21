import Foundation
import NotchCore

// Subagent scanner: meta parsing, transcript-tail parsing, status classification, row budget,
// and a scan over a fake ~/.claude/projects tree.
func registerSubagentTests() {
    // MARK: Meta (shapes copied from real files)
    let running = SubagentScanner.parseMeta(Data(#"{"agentType":"general-purpose","isBuiltIn":true,"launchedWithDefaults":true,"description":"Subagent progress list in notch","toolUseId":"toolu_01","spawnDepth":1,"requestShape":"background","requestNonInteractive":true,"model":"claude-opus-5-5","pickedEffortModel":"claude-opus-5-5"}"#.utf8))
    expectEqual(running?.description ?? "", "Subagent progress list in notch", "subagent meta: description")
    check("subagent meta: running has no finished key", running?.finished == nil)
    let finished = SubagentScanner.parseMeta(Data(#"{"agentType":"general-purpose","description":"Animation pass","finished":true,"isFork":true,"parentAgentId":"a1"}"#.utf8))
    check("subagent meta: finished", finished?.finished == true)
    check("subagent meta: fork", finished?.isFork == true && finished?.parentAgentId == "a1")
    let wf = SubagentScanner.parseMeta(Data(#"{"agentType":"workflow-subagent","description":"build:data","workflowPhase":"Build","inWorkflowRun":true}"#.utf8))
    expectEqual(wf?.workflowPhase ?? "", "Build", "subagent meta: workflow phase")
    check("subagent meta: garbage -> nil", SubagentScanner.parseMeta(Data("nope".utf8)) == nil)

    // MARK: Tail
    func asst(_ blocks: String) -> String {
        #"{"parentUuid":"p","isSidechain":true,"agentId":"x","type":"assistant","message":{"model":"claude-opus-5-5","id":"m","role":"assistant","content":[\#(blocks)],"usage":{"input_tokens":1,"output_tokens":1}},"timestamp":"2026-11-19T05:00:00Z"}"#
    }
    func tool(_ name: String, _ input: String) -> String { #"{"type":"tool_use","id":"t","name":"\#(name)","input":\#(input)}"# }
    let text = #"{"type":"text","text":"Building now.\nMore."}"#
    let user = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#
    // The tail window starts mid-line: that partial first line (an assistant line with a newer-
    // looking tool use) must be skipped, not half-parsed.
    let cut = String(asst(tool("Write", #"{"file_path":"/x/Cut.swift"}"#)).dropFirst(30))
    let lines = [cut, asst(text), asst(tool("Bash", #"{"command":"swift build 2>&1 | tail","description":"Build the package"}"#)),
                 user, #"{"type":"api-request","sessionId":"s"}"#]
    let tail = SubagentScanner.parseTail(Data(lines.joined(separator: "\n").utf8), isFileStart: false)
    expectEqual(tail.lastAction ?? "", "Bash: Build the package", "subagent tail: last tool use (description)")
    expectEqual(tail.lastText ?? "", "Building now.\nMore.", "subagent tail: last text")
    let onlyCut = SubagentScanner.parseTail(Data(cut.utf8), isFileStart: false)
    check("subagent tail: truncated first line ignored", onlyCut.lastAction == nil && onlyCut.lastText == nil)
    let whole = SubagentScanner.parseTail(Data(asst(tool("Edit", #"{"file_path":"/a/b/ExpandedView.swift"}"#)).utf8), isFileStart: true)
    expectEqual(whole.lastAction ?? "", "Edit ExpandedView.swift", "subagent tail: file start keeps first line")
    let handback = SubagentScanner.parseTail(Data([asst(tool("Read", #"{"file_path":"/a/Models.swift"}"#)),
                                                   asst(tool("SubagentHandback", #"{"message":"done"}"#))].joined(separator: "\n").utf8), isFileStart: true)
    expectEqual(handback.lastAction ?? "", "Read Models.swift", "subagent tail: handback skipped for real work")

    // MARK: describe
    expectEqual(SubagentScanner.describe(tool: "Bash", input: ["command": "cd \"/Users/x/Work Projects/app\" && swift build -c release"]),
                "Bash: swift build -c release", "describe: bash strips leading cd")
    expectEqual(SubagentScanner.describe(tool: "Bash", input: ["command": String(repeating: "a", count: 60)]),
                "Bash: " + String(repeating: "a", count: 40) + "…", "describe: bash 40 chars")
    expectEqual(SubagentScanner.describe(tool: "Grep", input: ["pattern": "TODO"]), "Grep: TODO", "describe: grep")
    expectEqual(SubagentScanner.describe(tool: "ToolSearch", input: [:]), "ToolSearch", "describe: other -> name")

    // MARK: Status
    let now = Date()
    expectEqual(SubagentRules.classify(finished: true, lastWrite: now.addingTimeInterval(-3600), now: now), .done, "status: finished -> done")
    expectEqual(SubagentRules.classify(finished: false, lastWrite: now.addingTimeInterval(-60), now: now), .running, "status: recent -> running")
    expectEqual(SubagentRules.classify(finished: false, lastWrite: now.addingTimeInterval(-6 * 60), now: now), .stalled, "status: silent 6m -> stalled")
    check("visible: stalled 7m", SubagentRules.isVisible(status: .stalled, lastWrite: now.addingTimeInterval(-7 * 60), now: now))
    check("visible: stalled 11m hidden", !SubagentRules.isVisible(status: .stalled, lastWrite: now.addingTimeInterval(-11 * 60), now: now))
    check("visible: done 11m hidden", !SubagentRules.isVisible(status: .done, lastWrite: now.addingTimeInterval(-11 * 60), now: now))
    check("visible: running always", SubagentRules.isVisible(status: .running, lastWrite: now.addingTimeInterval(-60), now: now))

    // MARK: Rows (4-row budget, workflow header + running agents first, "+N more")
    func info(_ id: String, _ st: SubagentStatus, ageMin: Double, run: String? = nil) -> SubagentInfo {
        SubagentInfo(agentId: id, description: id, workflowRunId: run, status: st,
                     startedAt: now.addingTimeInterval(-ageMin * 60 - 60), lastWrite: now.addingTimeInterval(-ageMin * 60))
    }
    let w = WorkflowInfo(runId: "wf_1", name: "wf", phase: "Build", doneCount: 1, totalCount: 3, status: .running,
                         startedAt: now.addingTimeInterval(-600), lastWrite: now,
                         agents: [info("w1", .done, ageMin: 3, run: "wf_1"), info("w2", .running, ageMin: 0, run: "wf_1"),
                                  info("w3", .running, ageMin: 0, run: "wf_1")])
    let subs = SessionSubagents(agents: [info("a-old", .done, ageMin: 30), info("a-done", .done, ageMin: 2),
                                         info("a-run", .running, ageMin: 0)], workflows: [w])
    expectEqual(subs.runningCount, 3, "rows: running count incl. workflow agents")
    expectEqual(subs.rows(now: now).map(\.id), ["w-wf_1", "a-w2", "a-w3", "a-a-run", "more"], "rows: order + budget")
    if case .more(let n) = subs.rows(now: now).last { expectEqual(n, 1, "rows: +N more counts hidden visible items") }
    expectEqual(SessionSubagents(agents: [info("x", .done, ageMin: 1)]).rows(now: now).count, 1, "rows: no more-row under budget")

    // MARK: AppState keeps only visible subagents of live sessions
    MainActor.assumeIsolated {
        let app = AppState()
        app.updateSessions([ClaudeSession(pid: 1, sessionId: "s1", cwd: "/tmp", name: "s1", status: .busy,
                                          startedAt: now, updatedAt: now)])
        app.updateSubagents(["s1": subs, "gone": subs], now: now)
        expectEqual(app.subagents(for: "s1").agents.map(\.agentId), ["a-done", "a-run"], "appState: old done agent dropped")
        check("appState: unknown session ignored", app.subagents["gone"] == nil)
        app.updateSessions([])
        check("appState: subagents pruned with session", app.subagents.isEmpty)
    }

    // MARK: Scan a fake projects tree
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("notch-subagents-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let cwd = "/Users/x/proj", sid = "sess-1"
    let sdir = root.appendingPathComponent(NotchPaths.encodeProjectDirName(cwd: cwd)).appendingPathComponent(sid)
    let sub = sdir.appendingPathComponent("subagents")
    let run = sub.appendingPathComponent("workflows/wf_abc")
    try? fm.createDirectory(at: run, withIntermediateDirectories: true)
    try? fm.createDirectory(at: sdir.appendingPathComponent("workflows/scripts"), withIntermediateDirectories: true)
    try? "".write(to: sdir.appendingPathComponent("workflows/scripts/my-flow-wf_abc.js"), atomically: true, encoding: .utf8)
    func write(_ s: String, _ url: URL, age: TimeInterval = 0) {
        try? s.write(to: url, atomically: false, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }
    let bash = asst(tool("Bash", #"{"command":"make"}"#))
    write(#"{"description":"Live one"}"#, sub.appendingPathComponent("agent-a1.meta.json"))
    write([bash, asst(text)].joined(separator: "\n") + "\n", sub.appendingPathComponent("agent-a1.jsonl"))
    write(#"{"description":"Old done","finished":true}"#, sub.appendingPathComponent("agent-a2.meta.json"))
    write(bash + "\n", sub.appendingPathComponent("agent-a2.jsonl"), age: 3600)
    write(#"{"description":"Killed"}"#, sub.appendingPathComponent("agent-a3.meta.json"))
    write(bash + "\n", sub.appendingPathComponent("agent-a3.jsonl"), age: 400)
    write(#"{"description":"build:data","workflowPhase":"Build"}"#, run.appendingPathComponent("agent-w1.meta.json"))
    write(bash + "\n", run.appendingPathComponent("agent-w1.jsonl"), age: 3000)
    write(#"{"description":"review","workflowPhase":"Review"}"#, run.appendingPathComponent("agent-w2.meta.json"))
    write(bash + "\n", run.appendingPathComponent("agent-w2.jsonl"))
    write([#"{"type":"launched"}"#,
           #"{"type":"started","agentId":"w1","label":"build:data","phase":"Build"}"#,
           #"{"type":"result","agentId":"w1","result":"ok"}"#,
           #"{"type":"started","agentId":"w2","label":"review","phase":"Review"}"#].joined(separator: "\n") + "\n",
          run.appendingPathComponent("journal.jsonl"))

    let scanner = SubagentScanner(projectsDir: root)
    func scan() -> SessionSubagents {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var r = SessionSubagents.empty
        Task.detached { r = await scanner.scan(sessionId: sid, cwd: cwd, transcriptPath: nil); sem.signal() }
        sem.wait()
        return r
    }
    var found = scan()
    let byId = Dictionary(found.agents.map { ($0.agentId, $0) }, uniquingKeysWith: { a, _ in a })
    expectEqual(byId["a1"]?.status, .running, "scan: live agent running")
    expectEqual(byId["a1"]?.lastAction ?? "", "Bash: make", "scan: last action")
    expectEqual(byId["a1"]?.toolUses ?? -1, 1, "scan: tool count")
    expectEqual(byId["a2"]?.status, .done, "scan: finished meta -> done")
    expectEqual(byId["a3"]?.status, .stalled, "scan: silent unfinished -> stalled")
    expectEqual(found.workflows.count, 1, "scan: workflow found")
    if let wfi = found.workflows.first {
        expectEqual(wfi.name, "my-flow", "scan: workflow name from script file")
        expectEqual(wfi.phase ?? "", "Review", "scan: workflow phase of running agent")
        expectEqual("\(wfi.doneCount)/\(wfi.totalCount)", "1/2", "scan: workflow done/total")
        expectEqual(wfi.status, .running, "scan: workflow running")
        expectEqual(wfi.agents.map(\.status), [.done, .running], "scan: workflow agent statuses (journal result -> done)")
    }
    // Appending: tool count grows incrementally, unchanged files come from cache.
    if let h = try? FileHandle(forWritingTo: sub.appendingPathComponent("agent-a1.jsonl")) {
        _ = try? h.seekToEnd()
        h.write(Data((asst(tool("Grep", #"{"pattern":"foo"}"#)) + "\n").utf8)); try? h.close()
    }
    found = scan()
    let a1 = found.agents.first { $0.agentId == "a1" }
    expectEqual(a1?.toolUses ?? -1, 2, "scan: incremental tool count")
    expectEqual(a1?.lastAction ?? "", "Grep: foo", "scan: action updated after append")
    expectEqual(a1?.lastText ?? "", "Building now.\nMore.", "scan: older text kept")
}
