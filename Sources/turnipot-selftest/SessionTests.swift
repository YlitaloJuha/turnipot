import Foundation
import NotchCore

// Owned by the Session implementer. Use check(_:_:) / expectEqual(_:_:_:) from main.swift.
func registerSessionTests() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notch-sessions-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let me = getpid()
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    // Real file shape (extra keys must be ignored).
    let good = #"{"pid":\#(me),"sessionId":"s-live","cwd":"/Users/x/Work Projects/acme-api","startedAt":\#(nowMs),"procStart":"Thu Nov 19 03:37:25 2026","version":"2.1.328","peerProtocol":1,"peerFeatures":["notify_idle"],"kind":"interactive","entrypoint":"cli","messagingSocketPath":"/tmp/cc-socks/1.sock","name":"acme-api-46","nameSource":"derived","status":"busy","updatedAt":1795059447220,"statusUpdatedAt":1795059447220}"#
    try? good.write(to: tmp.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
    try? "garbage".write(to: tmp.appendingPathComponent("123.json"), atomically: true, encoding: .utf8)
    try? "k".write(to: tmp.appendingPathComponent("\(me).abcdef.key"), atomically: true, encoding: .utf8)
    try? #"{"pid":99999999,"sessionId":"s-dead"}"#.write(to: tmp.appendingPathComponent("99999999.json"), atomically: true, encoding: .utf8)

    let files = SessionMonitor.loadSessionFiles(in: tmp)
    expectEqual(Set(files.map(\.sessionId)), ["s-live", "s-dead"], "sessions: decode, skip key/garbage")
    let live = files.first { $0.sessionId == "s-live" }
    expectEqual(live?.status ?? "", "busy", "sessions: status field")
    check("sessions: own pid alive", SessionMonitor.isAlive(pid: me))
    check("sessions: bogus pid dead", !SessionMonitor.isAlive(pid: 99_999_999))
    expectEqual(SessionMonitor.parentPid(of: me) ?? -1, getppid(), "sessions: parentPid via sysctl")
    check("sessions: parentPid of bogus nil", SessionMonitor.parentPid(of: 99_999_999) == nil)
    check("sessions: own pid not reused",
          !SessionMonitor.isPidReused(SessionFile(pid: me, sessionId: "x", startedAt: Double(nowMs))))
    check("sessions: pid reuse detected (process newer than startedAt)",
          SessionMonitor.isPidReused(SessionFile(pid: me, sessionId: "x", startedAt: Double(nowMs) - 3_600_000)))
    check("sessions: parentPid of launchd is nil", SessionMonitor.parentPid(of: 1) == nil)

    // End-to-end through SessionMonitor + AppState: own-process file is filtered (ppid==me rule
    // does not apply to self), dead pid filtered; busy -> idle produces a finished event.
    MainActor.assumeIsolated {
        let state = AppState()
        let monitor = SessionMonitor(appState: state, sessionsDir: tmp,
                                     transcriptReader: TranscriptReader(projectsDir: tmp))
        monitor.refresh()
        expectEqual(state.sessions.map(\.sessionId), ["s-live"], "sessions: only live pid")
        expectEqual(state.sessions.first?.shellPid ?? -1, getppid(), "sessions: shellPid = parent")
        expectEqual(state.sessions.first?.name ?? "", "acme-api-46", "sessions: name")
        let idle = good.replacingOccurrences(of: #""status":"busy""#, with: #""status":"idle""#)
        try? idle.write(to: tmp.appendingPathComponent("\(me).json"), atomically: true, encoding: .utf8)
        monitor.refresh()
        check("sessions: busy->idle finished event",
              state.events.contains { $0.kind == .sessionFinished(sessionId: "s-live") })
        monitor.stop()
    }

    // Opt-in: real ~/.claude/sessions (TURNIPOT_LIVE=1).
    if ProcessInfo.processInfo.environment["TURNIPOT_LIVE"] == "1" {
        for f in SessionMonitor.loadSessionFiles(in: NotchPaths.sessionsDir) {
            let alive = SessionMonitor.isAlive(pid: f.pid)
            let ppid = SessionMonitor.parentPid(of: f.pid)
            print("session live: pid=\(f.pid) name=\(f.name ?? "?") status=\(f.status ?? "?") entry=\(f.entrypoint ?? "?") alive=\(alive) shellPid=\(ppid.map(String.init) ?? "nil")")
        }
    }
}
