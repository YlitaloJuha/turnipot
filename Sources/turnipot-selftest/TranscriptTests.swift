import Foundation
import NotchCore

// Owned by the Transcript implementer. Use check(_:_:) / expectEqual(_:_:_:) from main.swift.
func registerTranscriptTests() {
    // Shapes mirror real transcript lines (one content block per line, usage repeated per id).
    func asst(_ id: String, _ block: String, input: Int = 2, cc: Int = 100, cr: Int = 1000, out: Int = 50,
              model: String = "claude-opus-5-5", ts: String = "2026-11-19T00:54:51.067Z", side: Bool = false) -> String {
        #"{"parentUuid":"p","isSidechain":\#(side),"type":"assistant","uuid":"u-\#(id)","timestamp":"\#(ts)","message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[\#(block)],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cc),"cache_read_input_tokens":\#(cr),"output_tokens":\#(out),"service_tier":"standard"}}}"#
    }
    let thinking = #"{"type":"thinking","thinking":"hmm","signature":"x"}"#
    func text(_ t: String) -> String { #"{"type":"text","text":"\#(t)"}"# }
    let tool = #"{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}"#
    let user = #"{"type":"user","message":{"role":"user","content":"hi assistant"}}"#

    var st = TranscriptReader.ParseState()
    let lines1 = [user, asst("m1", thinking), asst("m1", text("Hello")), asst("m1", tool), "not json {"]
    TranscriptReader.parse(lines: lines1.map { Substring($0) }, into: &st)
    expectEqual(st.summary.tokens.input, 2, "transcript: dedupe input")
    expectEqual(st.summary.tokens.cacheRead, 1000, "transcript: dedupe cacheRead")
    expectEqual(st.summary.tokens.output, 50, "transcript: dedupe output")
    expectEqual(st.summary.tokens.lastContext, 1102, "transcript: lastContext")
    expectEqual(st.summary.model ?? "", "claude-opus-5-5", "transcript: model")
    expectEqual(st.summary.lastAssistantText ?? "", "Hello", "transcript: text")
    check("transcript: timestamp parsed", st.summary.lastAssistantAt != nil)

    // Session description: ai-title, overridden by a /rename custom-title, latest of each wins.
    var tt = TranscriptReader.ParseState()
    TranscriptReader.parse(lines: [#"{"type":"ai-title","aiTitle":"First idea","sessionId":"s"}"#,
                                   #"{"type":"ai-title","aiTitle":"Notch companion app for Mac","sessionId":"s"}"#].map { Substring($0) }, into: &tt)
    expectEqual(tt.summary.title ?? "", "Notch companion app for Mac", "transcript: ai-title latest wins")
    TranscriptReader.parse(lines: [Substring(#"{"type":"custom-title","customTitle":"Notch app","sessionId":"s"}"#),
                                   Substring(#"{"type":"ai-title","aiTitle":"Later auto title","sessionId":"s"}"#)], into: &tt)
    expectEqual(tt.summary.title ?? "", "Notch app", "transcript: custom-title beats ai-title")

    // Second message with two text lines, later usage for m1 updated (latest wins), synthetic + sidechain ignored for text/model.
    let lines2 = [asst("m1", tool, out: 80), asst("m2", text("Done."), input: 3, cc: 0, cr: 2000, out: 10),
                  asst("m2", text("All tests pass.")),
                  asst("m3", text("API Error"), input: 0, cc: 0, cr: 0, out: 0, model: "<synthetic>"),
                  asst("s1", text("subagent says"), input: 5, cc: 0, cr: 0, out: 5, model: "claude-haiku", side: true)]
    TranscriptReader.parse(lines: lines2.map { Substring($0) }, into: &st)
    expectEqual(st.summary.tokens.output, 80 + 50 + 5, "transcript: latest usage per id wins + sidechain counted")
    expectEqual(st.summary.model ?? "", "claude-opus-5-5", "transcript: synthetic/sidechain model ignored")
    expectEqual(st.summary.lastAssistantText ?? "", "API Error", "transcript: latest text (synthetic error text kept)")

    // Incremental file reading with partial trailing line and truncation.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("turnipot-selftest-\(UUID().uuidString)")
    let cwd = "/Users/x/Work Projects/demo"
    let dir = tmp.appendingPathComponent(NotchPaths.encodeProjectDirName(cwd: cwd))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let sid = "abc-123"
    let file = dir.appendingPathComponent("\(sid).jsonl")
    let reader = TranscriptReader(projectsDir: tmp)

    func run<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached { result = await body(); sem.signal() }
        sem.wait()
        return result!
    }

    check("reader: missing -> nil", run { await reader.read(sessionId: sid, cwd: cwd) } == nil)
    let first = asst("a1", text("one"), out: 10) + "\n" + String(asst("a2", text("two"), out: 20).prefix(40))
    try? first.write(to: file, atomically: false, encoding: .utf8)
    var s = run { await reader.read(sessionId: sid, cwd: cwd) }
    expectEqual(s?.tokens.output ?? -1, 10, "reader: only complete lines")
    expectEqual(s?.transcriptPath ?? "", file.path, "reader: path")
    let rest = String(asst("a2", text("two"), out: 20).dropFirst(40)) + "\n"
    if let h = try? FileHandle(forWritingTo: file) { _ = try? h.seekToEnd(); h.write(rest.data(using: .utf8)!); try? h.close() }
    s = run { await reader.read(sessionId: sid, cwd: cwd) }
    expectEqual(s?.tokens.output ?? -1, 30, "reader: partial line completed")
    expectEqual(s?.lastAssistantText ?? "", "two", "reader: last text")
    s = run { await reader.read(sessionId: sid, cwd: cwd) }
    expectEqual(s?.tokens.output ?? -1, 30, "reader: no double count on reread")
    try? (asst("b1", text("fresh"), out: 7) + "\n").write(to: file, atomically: false, encoding: .utf8)
    s = run { await reader.read(sessionId: sid, cwd: cwd) }
    expectEqual(s?.tokens.output ?? -1, 7, "reader: truncation resets")

    // Fallback glob when cwd encoding doesn't match.
    s = run { await reader.read(sessionId: sid, cwd: "/some/other/place") }
    check("reader: glob fallback", s != nil)

    // Opt-in: read real transcripts of live sessions (TURNIPOT_LIVE=1).
    if ProcessInfo.processInfo.environment["TURNIPOT_LIVE"] == "1" {
        let live = TranscriptReader()
        for f in SessionMonitor.loadSessionFiles(in: NotchPaths.sessionsDir) {
            let id = f.sessionId, c = f.cwd ?? ""
            let t0 = Date()
            let sum = run { await live.read(sessionId: id, cwd: c) }
            let dt = Date().timeIntervalSince(t0)
            print(String(format: "transcript live: %@ %@ total=%@ ctx=%@ model=%@ text=%d chars (%.0f ms)",
                         f.name ?? "?", sum == nil ? "no transcript" : "ok",
                         TokenTotals.format(sum?.tokens.total ?? 0), TokenTotals.format(sum?.tokens.lastContext ?? 0),
                         sum?.model ?? "-", sum?.lastAssistantText?.count ?? 0, dt * 1000))
        }
    }
}
