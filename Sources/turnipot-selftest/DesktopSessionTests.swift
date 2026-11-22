import Foundation
import NotchCore

/// Claude Desktop session records: parsing, the cached index, side-session grouping in the panel
/// and "seen in Claude Desktop".
func registerDesktopSessionTests() {
    typealias CDS = ClaudeDesktopSessions
    func ms(_ t: Double) -> Double { t * 1000 }

    // MARK: Record parsing
    let full = #"{"sessionId":"local_c1","cliSessionId":"cli-c1","title":" Icons ","lastActivityAt":4000,"isArchived":false,"spawnedFrom":{"sessionId":"local_p","sideSession":true}}"#
    let r = CDS.Record.parse(Data(full.utf8))
    expectEqual(r?.localId, "local_c1", "desktop record: id")
    expectEqual(r?.cliSessionId, "cli-c1", "desktop record: cli id")
    expectEqual(r?.title, "Icons", "desktop record: title trimmed")
    expectEqual(r?.parentLocalId, "local_p", "desktop record: spawnedFrom parent")
    check("desktop record: invalid id rejected", CDS.Record.parse(Data(#"{"sessionId":"x y"}"#.utf8)) == nil)
    check("desktop record: junk rejected", CDS.Record.parse(Data("nope".utf8)) == nil)
    expectEqual(CDS.Record.parse(Data(#"{"sessionId":"local_a","title":"","spawnedFrom":{"sessionId":"local_a"}}"#.utf8))?.parentLocalId,
                nil, "desktop record: self-parent ignored")

    // MARK: Snapshot
    let snap = CDS.Snapshot(records: [
        .init(localId: "local_p", cliSessionId: "cli-p", title: "Parent"),
        .init(localId: "local_c1", cliSessionId: "cli-c1", title: "Child", parentLocalId: "local_p"),
        .init(localId: "local_old", cliSessionId: "cli-c1", lastActivityAt: Date(timeIntervalSince1970: 99), isArchived: true),
    ])
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

    // MARK: Claude Desktop records never mark a session seen
    MainActor.assumeIsolated {
        let app = AppState()
        let now = Date(timeIntervalSince1970: 2_000)
        func desk(_ id: String, _ status: SessionStatus) -> ClaudeSession {
            ClaudeSession(pid: 1, host: .claudeDesktop, sessionId: id, cwd: "/x", name: id, status: status, startedAt: t0, updatedAt: t0)
        }
        app.updateDesktopSessions(CDS.Snapshot(records: [.init(localId: "local_a", cliSessionId: "A", title: "T-A")]))
        app.updateSessions([desk("A", .busy)], now: now)
        expectEqual(app.sessions.first?.displayTitle, "T-A", "desktop: sidebar title shown")
        app.updateSessions([desk("A", .idle)], now: now.addingTimeInterval(10))
        app.updateDesktopSessions(CDS.Snapshot(records: [.init(localId: "local_a", cliSessionId: "A", title: "Renamed")]))
        check("desktop: record updates keep the done mark", app.isUnseen("A"))
        expectEqual(app.sessions.first?.displayTitle, "Renamed", "desktop: title follows Claude Desktop")
    }
}
