import Foundation
import NotchCore

/// Claude Desktop session records: parsing, the cached index, side-session grouping in the panel
/// and "seen in Claude Desktop".
func registerDesktopSessionTests() {
    typealias CDS = ClaudeDesktopSessions
    func ms(_ t: Double) -> Double { t * 1000 }

    // MARK: Record parsing
    let full = #"{"sessionId":"local_c1","cliSessionId":"cli-c1","title":" Icons ","lastFocusedAt":5000,"lastActivityAt":4000,"isArchived":false,"spawnedFrom":{"sessionId":"local_p","sideSession":true}}"#
    let r = CDS.Record.parse(Data(full.utf8))
    expectEqual(r?.localId, "local_c1", "desktop record: id")
    expectEqual(r?.cliSessionId, "cli-c1", "desktop record: cli id")
    expectEqual(r?.title, "Icons", "desktop record: title trimmed")
    expectEqual(r?.parentLocalId, "local_p", "desktop record: spawnedFrom parent")
    expectEqual(r?.lastFocusedAt, Date(timeIntervalSince1970: 5), "desktop record: lastFocusedAt ms")
    check("desktop record: invalid id rejected", CDS.Record.parse(Data(#"{"sessionId":"x y"}"#.utf8)) == nil)
    check("desktop record: junk rejected", CDS.Record.parse(Data("nope".utf8)) == nil)
    expectEqual(CDS.Record.parse(Data(#"{"sessionId":"local_a","title":"","spawnedFrom":{"sessionId":"local_a"}}"#.utf8))?.parentLocalId,
                nil, "desktop record: self-parent ignored")

    // MARK: Snapshot
    let snap = CDS.Snapshot(records: [
        .init(localId: "local_p", cliSessionId: "cli-p", title: "Parent", lastFocusedAt: Date(timeIntervalSince1970: 10)),
        .init(localId: "local_c1", cliSessionId: "cli-c1", title: "Child", parentLocalId: "local_p",
              lastFocusedAt: Date(timeIntervalSince1970: 30)),
        .init(localId: "local_old", cliSessionId: "cli-c1", lastActivityAt: Date(timeIntervalSince1970: 99), isArchived: true),
    ])
    expectEqual(snap.shownLocalId, "local_c1", "desktop snapshot: shown = last focused")
    let info = snap.info(cliSessionId: "cli-c1")
    expectEqual(info?.localId, "local_c1", "desktop snapshot: live record beats archived")
    expectEqual(info?.parentTitle, "Parent", "desktop snapshot: parent title")
    check("desktop snapshot: unknown cli id", snap.info(cliSessionId: "zzz") == nil)

    // MARK: Index (re-reads changed files only)
    let dir = URL(fileURLWithPath: "/tmp/notch-desktop-\(getpid())", isDirectory: true)
    let org = dir.appendingPathComponent("acct/org", isDirectory: true)
    try? FileManager.default.createDirectory(at: org, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func write(_ local: String, _ json: String, modified: Double) {
        let url = org.appendingPathComponent("\(local).json")
        try? json.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
    }
    write("local_a", #"{"sessionId":"local_a","cliSessionId":"cli-a","title":"One"}"#, modified: 100)
    try? "x".write(to: org.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let index = CDS.Index(sessionsDir: dir)
    func scan() -> CDS.Snapshot {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out = CDS.Snapshot.empty
        Task.detached { out = await index.scan(); sem.signal() }
        sem.wait()
        return out
    }
    expectEqual(scan().byCliSessionId["cli-a"]?.title, "One", "desktop index: first scan")
    write("local_a", #"{"sessionId":"local_a","cliSessionId":"cli-a","title":"Two"}"#, modified: 100)
    expectEqual(scan().byCliSessionId["cli-a"]?.title, "One", "desktop index: same mtime comes from cache")
    write("local_a", #"{"sessionId":"local_a","cliSessionId":"cli-a","title":"Two"}"#, modified: 200)
    expectEqual(scan().byCliSessionId["cli-a"]?.title, "Two", "desktop index: changed file re-read")
    try? FileManager.default.removeItem(at: org.appendingPathComponent("local_a.json"))
    check("desktop index: removed file dropped", scan().byLocalId.isEmpty)

    // MARK: Panel grouping
    let t0 = Date(timeIntervalSince1970: 1_000)
    func sess(_ id: String, local: String?, parent: String? = nil, _ status: SessionStatus = .idle) -> ClaudeSession {
        var s = ClaudeSession(pid: 1, host: local == nil ? .terminal : .claudeDesktop, sessionId: id, cwd: "/x",
                              name: id, status: status, startedAt: t0, updatedAt: t0)
        s.desktop = local.map { DesktopSessionInfo(localId: $0, parentLocalId: parent) }
        return s
    }
    let P = sess("P", local: "local_p"), C1 = sess("C1", local: "local_c1", parent: "local_p")
    let C2 = sess("C2", local: "local_c2", parent: "local_p"), G = sess("G", local: "local_g", parent: "local_c1")
    let X = sess("X", local: nil), O = sess("O", local: "local_o", parent: "local_gone")
    let rows = AttentionRules.groupedBySpawn([C2, X, P, O, C1, G])
    expectEqual(rows.map(\.id), ["P", "C2", "C1", "G", "X", "O"], "grouping: family sits where its first member is")
    expectEqual(rows.map(\.depth), [0, 1, 1, 2, 0, 0], "grouping: depths; missing parent stays top level")
    let cyc = AttentionRules.groupedBySpawn([sess("A", local: "local_a", parent: "local_b"), sess("B", local: "local_b", parent: "local_a")])
    expectEqual(cyc.count, 2, "grouping: a parent cycle still shows every session once")

    // MARK: Seen in Claude Desktop: only switching to the session there counts
    MainActor.assumeIsolated {
        func record(_ local: String, _ cli: String, focused: Double?) -> CDS.Record {
            .init(localId: local, cliSessionId: cli, title: "T-\(cli)", lastFocusedAt: focused.map { Date(timeIntervalSince1970: $0) })
        }
        func shown(a: Double, b: Double) -> CDS.Snapshot {
            CDS.Snapshot(records: [record("local_a", "A", focused: a), record("local_b", "B", focused: b)])
        }
        let app = AppState()
        let now = Date(timeIntervalSince1970: 2_000)
        func desk(_ id: String, _ status: SessionStatus) -> ClaudeSession {
            ClaudeSession(pid: 1, host: .claudeDesktop, sessionId: id, cwd: "/x", name: id, status: status, startedAt: t0, updatedAt: t0)
        }
        app.updateDesktopSessions(shown(a: 1_500, b: 1_000))    // Claude Desktop shows A
        app.updateSessions([desk("A", .busy), desk("B", .busy)], now: now)
        expectEqual(app.sessions.first { $0.sessionId == "A" }?.displayTitle, "T-A", "seen: Desktop title shown")
        app.updateSessions([desk("A", .idle), desk("B", .idle)], now: now.addingTimeInterval(10))
        check("seen: finishing while on screen still marks it", app.isUnseen("A") && app.isUnseen("B"))
        app.updateDesktopSessions(shown(a: 2_015, b: 1_000))    // A's tab visible again, still A
        check("seen: same session shown again doesn't count", app.isUnseen("A"))
        app.updateDesktopSessions(shown(a: 2_015, b: 2_020))    // the user clicks B in the sidebar
        check("seen: switching to it in Claude Desktop -> seen", !app.isUnseen("B"))
        check("seen: the session switched away from stays marked", app.isUnseen("A"))
        app.updateDesktopSessions(shown(a: 2_025, b: 2_020))    // and back to A
        check("seen: switching back -> seen", !app.isUnseen("A"))
    }
}
