import Foundation
import NotchCore

/// Reply reader: turn extraction (ReplyParser), backward chunked reading + cache (ReplyReader),
/// Markdown blocks, current context after compaction, AppState reader mode.
func registerReplyTests() {
    var seq = 0
    func ts() -> String { seq += 1; return String(format: "2026-11-19T10:%02d:%02d.000Z", seq / 60, seq % 60) }
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
    }
    func prompt(_ t: String, id: String, origin: String? = "human", extra: String = "") -> String {
        let o = origin.map { #","origin":{"kind":"\#($0)"}"# } ?? ""
        return #"{"type":"user","isSidechain":false,"uuid":"\#(id)","timestamp":"\#(ts())"\#(o)\#(extra),"message":{"role":"user","content":"\#(esc(t))"}}"#
    }
    func blocksPrompt(_ blocks: [String], id: String) -> String {
        let b = blocks.map { #"{"type":"text","text":"\#(esc($0))"}"# }.joined(separator: ",")
        return #"{"type":"user","isSidechain":false,"uuid":"\#(id)","timestamp":"\#(ts())","origin":{"kind":"human"},"message":{"role":"user","content":[\#(b)]}}"#
    }
    func toolResult(_ id: String) -> String {
        #"{"type":"user","isSidechain":false,"uuid":"\#(id)","timestamp":"\#(ts())","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"ok \"type\":\"user\""}]},"toolUseResult":{}}"#
    }
    func asst(_ t: String, id: String, side: Bool = false, model: String = "claude-opus-5-5") -> String {
        #"{"type":"assistant","isSidechain":\#(side),"uuid":"\#(id)","timestamp":"\#(ts())","message":{"id":"m-\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"\#(esc(t))"}]}}"#
    }
    func thinking(_ id: String) -> String {
        #"{"type":"assistant","isSidechain":false,"uuid":"\#(id)","timestamp":"\#(ts())","message":{"id":"m-\#(id)","model":"claude-opus-5-5","role":"assistant","content":[{"type":"thinking","thinking":"secret plan","signature":"x"}]}}"#
    }
    func toolUse(_ id: String) -> String {
        #"{"type":"assistant","isSidechain":false,"uuid":"\#(id)","timestamp":"\#(ts())","message":{"id":"m-\#(id)","model":"claude-opus-5-5","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
    }

    // MARK: Prompt classification
    typealias P = ReplyParser
    expectEqual(P.promptText(["Fix the build please"]), "Fix the build please", "prompt: plain")
    expectEqual(P.promptText(["<system-reminder>\nscratch dir\n</system-reminder>", "how to disable it?"]), "how to disable it?", "prompt: system-reminder block stripped")
    expectEqual(P.promptText(["<ide_opened_file>The user opened x.</ide_opened_file>", "can serial be altered?"]), "can serial be altered?", "prompt: ide_opened_file stripped")
    expectEqual(P.promptText(["<system-reminder>only context</system-reminder>"]), nil, "prompt: reminder only -> not a prompt")
    expectEqual(P.promptText(["<task-notification>\n<task-id>x</task-id>\n</task-notification>"]), nil, "prompt: task notification")
    expectEqual(P.promptText(["<local-command-stdout>Login successful</local-command-stdout>"]), nil, "prompt: local command output")
    expectEqual(P.promptText(["<bash-input>ls</bash-input><bash-stdout></bash-stdout>"]), nil, "prompt: bash mode echo")
    expectEqual(P.promptText(["[Request interrupted by user for tool use]"]), nil, "prompt: interrupted marker")
    expectEqual(P.promptText(["<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>PR 12</command-args>"]), "/review PR 12", "prompt: slash command")
    expectEqual(P.promptText(["<!-- reply 2 -->\n> quoted bit\n\nthese can be left out."]), "these can be left out.", "prompt: reply marker + quote skipped")
    expectEqual(P.promptText(["❯ would we be able\n  to make it"]), "would we be able", "prompt: first line, ❯ stripped")
    check("prompt: truncated", (P.promptText([String(repeating: "a", count: 400)])?.count ?? 0) == P.maxPromptLength)

    // MARK: Turn extraction
    let lines = [
        asst("leading text before any prompt", id: "x0"),
        prompt("First question", id: "p1"),
        thinking("a1"), asst("Part one.", id: "a2"), toolUse("a3"), toolResult("r1"),
        asst("Part two.", id: "a4"),
        asst("subagent noise", id: "s1", side: true),
        asst("API Error", id: "e1", model: "<synthetic>"),
        prompt("<task-notification>\n<task-id>w</task-id>\n</task-notification>", id: "tn", origin: "task-notification"),
        asst("After the notification.", id: "a5"),
        prompt("meta context", id: "meta", extra: #","isMeta":true"#),
        prompt("summary of earlier", id: "cs", origin: nil, extra: #","isCompactSummary":true"#),
        blocksPrompt(["<system-reminder>ctx</system-reminder>", "Second question\nmore lines"], id: "p2"),
        asst("Answer two.", id: "b1"),
        prompt("<command-name>/rename</command-name>\n<command-message>rename</command-message>\n<command-args>x</command-args>", id: "cmd", origin: nil),
        prompt("<local-command-stdout>Renamed</local-command-stdout>", id: "out", origin: nil),
        prompt("Third question", id: "p3"),
    ]
    let recs = P.records(lines: lines.map { Substring($0) })
    let turns = P.turns(from: recs, includeLeading: false)
    expectEqual(turns.map(\.id), ["p1", "p2", "cmd", "p3"], "turns: only real prompts start turns")
    expectEqual(turns.first?.text, "Part one.\n\nPart two.\n\nAfter the notification.", "turns: multi-message reply, thinking/tool/sidechain/synthetic ignored, notification text stays in turn")
    expectEqual(turns.first?.prompt, "First question", "turns: prompt text")
    check("turns: timestamps", turns.first?.promptAt != nil && turns.first?.repliedAt != nil && turns.first!.repliedAt! > turns.first!.promptAt!)
    expectEqual(turns[1].prompt, "Second question", "turns: reminder block stripped from prompt")
    expectEqual(turns[1].text, "Answer two.", "turns: second reply")
    let recent = P.recent(turns, limit: 10)
    expectEqual(recent.map(\.id), ["p1", "p2", "p3"], "recent: empty command turn dropped, empty newest kept")
    check("recent: newest is in progress", recent.last?.isEmpty == true)
    expectEqual(P.turns(from: recs, includeLeading: true).first?.text, "leading text before any prompt", "turns: leading text at file start")
    expectEqual(P.recent(turns, limit: 2).map(\.id), ["p2", "p3"], "recent: limit keeps newest")

    // MARK: Backward chunked reading
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notch-replies-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let file = tmp.appendingPathComponent("s.jsonl")
    var body: [String] = []
    for k in 1...30 {
        body.append(prompt("Question \(k)", id: "q\(k)"))
        body.append(toolResult("r\(k)"))
        // Long reply lines so chunk boundaries cut through lines.
        body.append(asst("Reply \(k): " + String(repeating: "lorem ipsum ", count: 40 + k), id: "a\(k)"))
    }
    let content = body.joined(separator: "\n") + "\n"
    try? content.write(to: file, atomically: false, encoding: .utf8)

    func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached { result = await body(); sem.signal() }
        sem.wait()
        return result!
    }

    let reader = ReplyReader(projectsDir: tmp, chunkSize: 700, maxTurns: 10)
    var r = run { await reader.replies(key: "s", url: file) }
    expectEqual(r?.turns.count, 10, "chunked: 10 turns")
    expectEqual(r?.turns.first?.prompt, "Question 21", "chunked: oldest of the last 10")
    expectEqual(r?.turns.last?.prompt, "Question 30", "chunked: newest last")
    check("chunked: reply text intact across chunk boundaries",
          r?.turns.allSatisfy { t in t.text.hasPrefix("Reply ") && t.text.hasSuffix("ipsum") } == true)
    check("chunked: read only the tail", (r?.bytesScanned ?? 0) < UInt64(content.utf8.count))
    expectEqual(r?.source, .full, "chunked: first read is full")
    // Line split right across a chunk boundary: compare against a whole-file parse.
    let reader2 = ReplyReader(projectsDir: tmp, chunkSize: 97, maxTurns: 30)
    let all = run { await reader2.replies(key: "s", url: file) }
    let direct = P.recent(P.turns(from: P.records(lines: content.split(separator: "\n")), includeLeading: true), limit: 30)
    expectEqual(all?.turns, direct, "chunked: tiny chunks == whole-file parse")
    r = run { await reader.replies(key: "s", url: file) }
    expectEqual(r?.source, .cache, "cache: unchanged file served from cache")

    // Growth: partial trailing line ignored, then completed; new turn appears incrementally.
    let more = prompt("Question 31", id: "q31") + "\n" + String(asst("Reply 31 done", id: "a31").prefix(50))
    if let h = try? FileHandle(forWritingTo: file) { _ = try? h.seekToEnd(); h.write(Data(more.utf8)); try? h.close() }
    r = run { await reader.replies(key: "s", url: file) }
    expectEqual(r?.source, .incremental, "growth: incremental")
    expectEqual(r?.turns.last?.prompt, "Question 31", "growth: new prompt")
    check("growth: in-progress turn empty (partial line skipped)", r?.turns.last?.isEmpty == true)
    expectEqual(r?.turns.count, 10, "growth: still 10 turns (oldest dropped)")
    let rest = String(asst("Reply 31 done", id: "a31").dropFirst(50)) + "\n"
    if let h = try? FileHandle(forWritingTo: file) { _ = try? h.seekToEnd(); h.write(Data(rest.utf8)); try? h.close() }
    r = run { await reader.replies(key: "s", url: file) }
    expectEqual(r?.turns.last?.text, "Reply 31 done", "growth: completed line parsed")
    expectEqual(r?.turns.first?.prompt, "Question 22", "growth: window slides")
    // Truncation / rewrite: full reload.
    try? (prompt("Fresh", id: "f1") + "\n" + asst("New file", id: "f2") + "\n").write(to: file, atomically: true, encoding: .utf8)
    r = run { await reader.replies(key: "s", url: file) }
    expectEqual(r?.source, .full, "rewrite: full reload")
    expectEqual(r?.turns.map(\.text), ["New file"], "rewrite: new content")

    // MARK: Markdown blocks
    let md = """
    # Title
    Intro with **bold** and `code`.
    still intro

    - one
    - two
      continued
      - nested
    1. first
    2) second

    ```swift
    let x = 1
    # not a heading
    ```
    > quoted
    ---
    | a | bb |
    |---|---|
    | ccc | d |
    ~~~
    unclosed tilde
    """
    let blocks = MarkdownBlocks.parse(md)
    expectEqual(blocks.first, .heading(level: 1, text: "Title"), "md: heading")
    expectEqual(blocks[1], .paragraph("Intro with **bold** and `code`.\nstill intro"), "md: paragraph keeps inline markup + line break")
    expectEqual(blocks[2], .listItem(marker: "•", indent: 0, text: "one"), "md: bullet")
    expectEqual(blocks[3], .listItem(marker: "•", indent: 0, text: "two\ncontinued"), "md: continuation line")
    expectEqual(blocks[4], .listItem(marker: "•", indent: 1, text: "nested"), "md: nested bullet")
    expectEqual(blocks[5], .listItem(marker: "1.", indent: 0, text: "first"), "md: numbered")
    expectEqual(blocks[6], .listItem(marker: "2.", indent: 0, text: "second"), "md: numbered with )")
    expectEqual(blocks[7], .code(language: "swift", text: "let x = 1\n# not a heading"), "md: fenced code, # inside not a heading")
    expectEqual(blocks[8], .quote("quoted"), "md: quote")
    expectEqual(blocks[9], .rule, "md: rule")
    expectEqual(blocks[10], .table(MDTable(header: ["a", "bb"], rows: [["ccc", "d"]])), "md: table parsed")
    if case .table(let t) = blocks[10] {
        expectEqual(t.grid, "a   │ bb\n────┼───\nccc │ d", "md: table grid aligned")
        expectEqual(t.gridWidth, 8, "md: table grid width")
    }
    let wide = MarkdownBlocks.table(["| Where | Now | Proposed |", "|---|---|---|",
                                     "| `f` | **no** return type | `-> A` |", "| g | | a \\| b |"])
    expectEqual(wide.records, ["**Where:** `f`\n**Now:** **no** return type\n**Proposed:** `-> A`", "**Where:** g\n**Proposed:** a | b"],
                "md: table records keep inline markup, skip empty cells, unescape pipes")
    expectEqual(MarkdownBlocks.table(["| x | y |"]).grid, "x │ y", "md: headerless table")
    expectEqual(blocks[11], .code(language: nil, text: "unclosed tilde"), "md: unclosed fence runs to end")
    expectEqual(MarkdownBlocks.parse("Use ```inline``` here"), [.paragraph("Use ```inline``` here")], "md: one-line triple backticks are inline")
    expectEqual(MarkdownBlocks.parse("1. step\n   ```sh\n   make\n   ```"),
                [.listItem(marker: "1.", indent: 0, text: "step"), .code(language: "sh", text: "make")], "md: indented fence in a list")
    expectEqual(MarkdownBlocks.parse("````md\n```inner```\n````"), [.code(language: "md", text: "```inner```")], "md: longer fence wraps shorter")

    // MARK: Current context (lastContext) after compaction
    func usageLine(_ id: String, ctx: Int, side: Bool = false, model: String = "claude-opus-5-5") -> String {
        #"{"type":"assistant","isSidechain":\#(side),"uuid":"u\#(id)","timestamp":"\#(ts())","message":{"id":"\#(id)","model":"\#(model)","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":\#(ctx - 1),"cache_read_input_tokens":0,"output_tokens":10}}}"#
    }
    var st = TranscriptReader.ParseState()
    TranscriptReader.parse(lines: [usageLine("m1", ctx: 50_000), usageLine("m2", ctx: 232_000), usageLine("m3", ctx: 120_000)].map { Substring($0) }, into: &st)
    expectEqual(st.summary.tokens.lastContext, 120_000, "context: newest main-chain message by file order, not max")
    TranscriptReader.parse(lines: [usageLine("s1", ctx: 9_000, side: true), usageLine("e1", ctx: 3, model: "<synthetic>")].map { Substring($0) }, into: &st)
    expectEqual(st.summary.tokens.lastContext, 120_000, "context: sidechain + synthetic ignored")
    let boundary = #"{"type":"system","subtype":"compact_boundary","isSidechain":false,"content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":232621,"postTokens":11925}}"#
    let summary = #"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued..."}}"#
    TranscriptReader.parse(lines: [Substring(boundary), Substring(summary)], into: &st)
    expectEqual(st.summary.tokens.lastContext, 11_925, "context: drops to postTokens at the compact boundary")
    TranscriptReader.parse(lines: [Substring(usageLine("m4", ctx: 18_500))], into: &st)
    expectEqual(st.summary.tokens.lastContext, 18_500, "context: next message after compaction")
    check("context: cumulative total keeps growing", st.summary.tokens.total > 400_000)

    // MARK: AppState reader mode
    MainActor.assumeIsolated {
        let app = AppState()
        let t0 = Date()
        func s(_ id: String, _ status: SessionStatus) -> ClaudeSession {
            ClaudeSession(pid: 1, sessionId: id, cwd: "/tmp", name: id, status: status, startedAt: t0, updatedAt: t0)
        }
        app.updateSessions([s("A", .busy), s("B", .idle)], now: t0)
        app.updateSessions([s("A", .idle), s("B", .idle)], now: t0.addingTimeInterval(5))
        check("reader: A unseen + finished event", app.isUnseen("A") && app.latestFinishedSessionId == "A")
        app.openReader(sessionId: "A")
        expectEqual(app.mode, .reader(sessionId: "A"), "reader: mode")
        check("reader: opening marks seen and drops its drop-down", !app.isUnseen("A") && app.latestFinishedSessionId == nil)
        app.setHovering(true); app.setHovering(false)
        expectEqual(app.mode, .reader(sessionId: "A"), "reader: hover-out keeps it (pinned)")
        app.updateSessions([s("A", .busy), s("B", .idle)], now: t0.addingTimeInterval(10))
        app.updateSessions([s("A", .idle), s("B", .idle)], now: t0.addingTimeInterval(20))
        check("reader: finishing while read is not unseen, no drop-down", !app.isUnseen("A") && app.latestFinishedSessionId == nil)
        expectEqual(app.mode, .reader(sessionId: "A"), "reader: stays open on new reply")
        let req = PermissionRequest(sessionId: "B", toolName: "Bash", summary: "ls", toolInput: .null, raw: .null)
        app.enqueuePermission(req) { _ in }
        if case .permission = app.mode {} else { check("reader: permission beats reader", false) }
        app.resolvePermission(id: req.id, decision: .ask)
        expectEqual(app.mode, .reader(sessionId: "A"), "reader: back after permission")
        app.readerBack()
        check("reader: back -> pinned panel", app.mode == .expanded && app.isPinnedExpanded)
        app.openReader(sessionId: "B")
        app.closeReader()
        check("reader: close -> collapsed", app.mode == .collapsed && app.readerSessionId == nil)
        app.openReader(sessionId: "B")
        app.updateSessions([s("A", .idle)], now: t0.addingTimeInterval(30))
        check("reader: session ended -> closed", app.readerSessionId == nil && app.mode == .collapsed)
        app.openReader(sessionId: "nope")
        check("reader: unknown session ignored", app.readerSessionId == nil)
    }
}
