import Foundation

/// Maps a Claude Code session id to Claude Desktop's own session id, so the panel can open that
/// exact session. Claude Desktop keeps one JSON record per Code-tab session under
/// `claude-code-sessions/<account>/<org>/local_<uuid>.json` with (among others)
/// `"sessionId": "local_<uuid>"` and `"cliSessionId": "<Claude Code session id>"` (verified).
public enum ClaudeDesktopSessions {
    /// Claude Desktop accepts only this shape in `claude://code/continue?session=` (verified).
    static let localIdPattern = try! NSRegularExpression(pattern: "^local_[A-Za-z0-9-]{1,64}$")

    /// `claude://code/continue?session=local_…` for the session, or nil when none matches.
    public static func deepLink(cliSessionId: String, sessionsDir: URL) -> String? {
        guard let id = localSessionId(cliSessionId: cliSessionId, sessionsDir: sessionsDir) else { return nil }
        return "claude://code/continue?session=\(id)"
    }

    /// Claude Desktop's `local_…` id for `cliSessionId`. Prefers a non-archived record, then the
    /// most recent activity (a resumed session can leave more than one record).
    public static func localSessionId(cliSessionId: String, sessionsDir: URL) -> String? {
        guard !cliSessionId.isEmpty else { return nil }
        let fm = FileManager.default
        let needle = Data(cliSessionId.utf8)
        var best: (archived: Bool, activity: Double, id: String)?
        for account in (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? [] {
            for org in (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
                for file in (try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil)) ?? [] {
                    let name = file.lastPathComponent
                    guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                          let data = try? Data(contentsOf: file),
                          data.range(of: needle) != nil,   // cheap pre-filter: there are hundreds
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          obj["cliSessionId"] as? String == cliSessionId,
                          let id = obj["sessionId"] as? String,
                          localIdPattern.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
                    else { continue }
                    let archived = obj["isArchived"] as? Bool ?? false
                    let activity = (obj["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0
                    if let b = best, (b.archived ? 1 : 0, -b.activity) <= (archived ? 1 : 0, -activity) { continue }
                    best = (archived, activity, id)
                }
            }
        }
        return best?.id
    }
}
