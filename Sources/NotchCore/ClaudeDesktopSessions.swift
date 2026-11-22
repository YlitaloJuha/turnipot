import Foundation

/// Reads Claude Desktop's Code-tab session records: one JSON file per session under
/// `claude-code-sessions/<account>/<org>/local_<uuid>.json` with (among others, all verified)
///   "sessionId": "local_<uuid>"          Claude Desktop's id (what its deep link takes)
///   "cliSessionId": "<uuid>"             the Claude Code session id Turnipot tracks
///   "title", "isArchived", "lastActivityAt" (ms)
///   "lastFocusedAt" (ms)                 written each time the session's tab becomes visible
///   "spawnedFrom": {"sessionId": "local_…", "sideSession": true, …}   side sessions only
/// None of this is documented, so every field is optional and anything unexpected is skipped.
public enum ClaudeDesktopSessions {
    /// Claude Desktop accepts only this shape in `claude://code/continue?session=` (verified).
    static let localIdPattern = try! NSRegularExpression(pattern: "^local_[A-Za-z0-9-]{1,64}$")

    static func isLocalId(_ id: String) -> Bool {
        localIdPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
    }

    /// One session record (only the fields Turnipot uses).
    public struct Record: Equatable, Sendable {
        public var localId: String
        public var cliSessionId: String?
        public var title: String?
        public var parentLocalId: String?
        public var lastFocusedAt: Date?
        public var lastActivityAt: Date?
        public var isArchived: Bool

        public init(localId: String, cliSessionId: String? = nil, title: String? = nil, parentLocalId: String? = nil,
                    lastFocusedAt: Date? = nil, lastActivityAt: Date? = nil, isArchived: Bool = false) {
            self.localId = localId; self.cliSessionId = cliSessionId; self.title = title
            self.parentLocalId = parentLocalId; self.lastFocusedAt = lastFocusedAt
            self.lastActivityAt = lastActivityAt; self.isArchived = isArchived
        }

        /// nil unless the data is a record with a valid `local_…` id.
        public static func parse(_ data: Data) -> Record? {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = obj["sessionId"] as? String, isLocalId(id) else { return nil }
            func date(_ key: String) -> Date? {
                guard let ms = (obj[key] as? NSNumber)?.doubleValue, ms > 0 else { return nil }
                return Date(timeIntervalSince1970: ms / 1000)
            }
            let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = (obj["spawnedFrom"] as? [String: Any])?["sessionId"] as? String
            return Record(localId: id, cliSessionId: obj["cliSessionId"] as? String,
                          title: title?.isEmpty == false ? title : nil,
                          parentLocalId: parent.flatMap { isLocalId($0) && $0 != id ? $0 : nil },
                          lastFocusedAt: date("lastFocusedAt"), lastActivityAt: date("lastActivityAt"),
                          isArchived: obj["isArchived"] as? Bool ?? false)
        }

        /// Which of two records for the same Claude Code session wins: live over archived, then
        /// the most recent activity (a resumed session can leave more than one record).
        func preferred(over other: Record) -> Bool {
            if isArchived != other.isArchived { return !isArchived }
            return (lastActivityAt ?? .distantPast) > (other.lastActivityAt ?? .distantPast)
        }
    }

    /// All records at one moment.
    public struct Snapshot: Equatable, Sendable {
        public var byLocalId: [String: Record]
        public var byCliSessionId: [String: Record]
        /// The session Claude Desktop shows now: the one whose tab became visible last.
        public var shownLocalId: String?

        public static let empty = Snapshot(records: [])

        public init(records: [Record]) {
            var local: [String: Record] = [:], cli: [String: Record] = [:]
            var shown: Record?
            for r in records {
                local[r.localId] = r
                if let c = r.cliSessionId, !c.isEmpty, cli[c].map({ r.preferred(over: $0) }) ?? true { cli[c] = r }
                if let f = r.lastFocusedAt, f > (shown?.lastFocusedAt ?? .distantPast) { shown = r }
            }
            byLocalId = local; byCliSessionId = cli; shownLocalId = shown?.localId
        }

        /// What the panel needs for a Claude Code session, or nil when Claude Desktop has no record.
        public func info(cliSessionId: String) -> DesktopSessionInfo? {
            guard let r = byCliSessionId[cliSessionId] else { return nil }
            return DesktopSessionInfo(localId: r.localId, title: r.title, parentLocalId: r.parentLocalId,
                                      parentTitle: r.parentLocalId.flatMap { byLocalId[$0]?.title },
                                      lastFocusedAt: r.lastFocusedAt)
        }
    }

    /// `claude://code/continue?session=local_…` for the session, or nil when none matches.
    public static func deepLink(cliSessionId: String, sessionsDir: URL) -> String? {
        guard let id = localSessionId(cliSessionId: cliSessionId, sessionsDir: sessionsDir) else { return nil }
        return "claude://code/continue?session=\(id)"
    }

    /// Claude Desktop's `local_…` id for `cliSessionId` (one-off lookup, no cache).
    public static func localSessionId(cliSessionId: String, sessionsDir: URL) -> String? {
        guard !cliSessionId.isEmpty else { return nil }
        let needle = Data(cliSessionId.utf8)
        var best: Record?
        for file in recordFiles(in: sessionsDir) {
            guard let data = try? Data(contentsOf: file),
                  data.range(of: needle) != nil,   // cheap pre-filter: there are hundreds
                  let r = Record.parse(data), r.cliSessionId == cliSessionId else { continue }
            if best.map({ r.preferred(over: $0) }) ?? true { best = r }
        }
        return best?.localId
    }

    /// `<sessionsDir>/<account>/<org>/local_*.json`.
    static func recordFiles(in sessionsDir: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for account in (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [] {
                    let name = file.lastPathComponent
                    if name.hasPrefix("local_"), name.hasSuffix(".json") { out.append(file) }
                }
            }
        }
        return out
    }

    /// Re-reads only the records whose file changed since the last scan (by modification date),
    /// so polling every couple of seconds stays cheap with a thousand records on disk.
    public actor Index {
        public let sessionsDir: URL
        private var cache: [String: (modified: Date, record: Record?)] = [:]

        public init(sessionsDir: URL = NotchPaths.claudeDesktopSessionsDir) { self.sessionsDir = sessionsDir }

        public func scan() -> Snapshot {
            var next: [String: (modified: Date, record: Record?)] = [:]
            var records: [Record] = []
            for file in ClaudeDesktopSessions.recordFiles(in: sessionsDir) {
                let path = file.path
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                else { continue }
                let entry: (modified: Date, record: Record?)
                if let cached = cache[path], cached.modified == modified { entry = cached }
                else { entry = (modified, (try? Data(contentsOf: file)).flatMap(Record.parse)) }
                next[path] = entry
                if let r = entry.record { records.append(r) }
            }
            cache = next
            return Snapshot(records: records)
        }
    }
}

/// Claude Desktop's view of a live session (see `ClaudeDesktopSessions`).
public struct DesktopSessionInfo: Equatable, Sendable {
    public var localId: String
    /// The title in Claude Desktop's sidebar.
    public var title: String?
    /// The session that started this one as a side session, and its title.
    public var parentLocalId: String?
    public var parentTitle: String?
    /// Last time its tab became visible in Claude Desktop.
    public var lastFocusedAt: Date?

    public init(localId: String, title: String? = nil, parentLocalId: String? = nil, parentTitle: String? = nil,
                lastFocusedAt: Date? = nil) {
        self.localId = localId; self.title = title; self.parentLocalId = parentLocalId
        self.parentTitle = parentTitle; self.lastFocusedAt = lastFocusedAt
    }
}
