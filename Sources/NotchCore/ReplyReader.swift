import Foundation

// "Reply reader": the session's recent assistant replies in full, one per turn.
// A turn runs from a real user prompt up to the next real user prompt; its reply is every main-
// thread assistant text block in between, joined in order. Thinking, tool_use, tool results,
// sidechain (subagent) lines, synthetic messages and injected user lines (task notifications,
// system reminders, slash-command output, bash-mode echoes, "[Request interrupted…]", isMeta /
// compact summaries) never start a turn or add text.

/// One turn of a session: what the user asked and everything Claude wrote back.
public struct ReplyTurn: Identifiable, Equatable, Sendable {
    /// uuid of the prompt line (or of the first assistant line when the turn has no prompt,
    /// i.e. the transcript starts with assistant text).
    public var id: String
    /// First non-empty line of the prompt, cleaned and truncated (`ReplyParser.maxPromptLength`).
    public var prompt: String?
    public var promptAt: Date?
    /// Assistant text blocks of the turn joined with blank lines (Markdown).
    public var text: String
    /// Timestamp of the latest assistant text in the turn.
    public var repliedAt: Date?

    public init(id: String, prompt: String?, promptAt: Date?, text: String, repliedAt: Date?) {
        self.id = id; self.prompt = prompt; self.promptAt = promptAt; self.text = text; self.repliedAt = repliedAt
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// Pure parsing of transcript lines into turn records (unit-tested).
public enum ReplyParser {
    public static let maxPromptLength = 160

    /// What a transcript line contributes to the reader.
    public enum Record: Equatable, Sendable {
        /// A real user prompt (starts a turn).
        case prompt(id: String, text: String, at: Date?)
        /// Main-thread assistant text (one or more text blocks of one line).
        case text(id: String, text: String, at: Date?)
    }

    /// Parse complete JSONL lines (file order) into records. Malformed / irrelevant lines are skipped.
    public static func records(lines: [Substring]) -> [Record] {
        var out: [Record] = []
        for line in lines { if let r = record(line) { out.append(r) } }
        return out
    }

    public static func record(_ line: Substring) -> Record? {
        // Cheap pre-filters before JSON decoding (lines can be megabytes: tool results, images).
        let isUser = line.contains("\"type\":\"user\"")
        let isAssistant = !isUser && line.contains("\"type\":\"assistant\"")
        guard isUser || isAssistant else { return nil }
        if line.contains("\"isSidechain\":true") { return nil }
        // Tool results (structural, unescaped quotes: a prompt *mentioning* tool_result is escaped).
        if isUser && line.contains("\"type\":\"tool_result\"") { return nil }
        if isAssistant && !line.contains("\"type\":\"text\"") { return nil }   // thinking / tool_use only
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String,
              let message = obj["message"] as? [String: Any] else { return nil }
        if obj["isSidechain"] as? Bool == true { return nil }
        let uuid = (obj["uuid"] as? String) ?? UUID().uuidString
        let at = (obj["timestamp"] as? String).flatMap(TranscriptReader.parseDate)

        if type == "assistant" {
            if message["model"] as? String == "<synthetic>" { return nil }
            var texts: [String] = []
            if let content = message["content"] as? [[String: Any]] {
                for b in content where b["type"] as? String == "text" {
                    if let t = b["text"] as? String { texts.append(t) }
                }
            } else if let s = message["content"] as? String {
                texts.append(s)
            }
            let joined = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            return joined.isEmpty ? nil : .text(id: uuid, text: joined, at: at)
        }

        guard type == "user" else { return nil }
        if obj["isMeta"] as? Bool == true || obj["isCompactSummary"] as? Bool == true { return nil }
        // Newer transcripts tag who produced the line: only the human counts.
        if let origin = obj["origin"] as? [String: Any], let kind = origin["kind"] as? String, kind != "human" {
            return nil
        }
        var blocks: [String] = []
        if let s = message["content"] as? String {
            blocks = [s]
        } else if let content = message["content"] as? [[String: Any]] {
            if content.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            blocks = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            // Image-only prompt: still a prompt.
            if blocks.isEmpty, content.contains(where: { $0["type"] as? String == "image" }) { blocks = ["[Image]"] }
        }
        guard let text = promptText(blocks) else { return nil }
        return .prompt(id: uuid, text: text, at: at)
    }

    /// Tags whose whole element is context injected around (or instead of) a prompt.
    static let injectedTags = ["system-reminder", "ide_opened_file", "ide_selection", "local-command-caveat",
                               "task-notification", "user-memory-input"]
    /// A line starting with one of these is not a prompt (no assistant reply follows).
    static let nonPromptPrefixes = ["<task-notification", "<local-command-stdout", "<local-command-stderr",
                                    "<bash-input", "<bash-stdout", "<bash-stderr",
                                    "[Request interrupted by user", "Caveat: The messages below"]

    /// The prompt's display text (first non-empty line, truncated), or nil if the line is not a
    /// real prompt.
    public static func promptText(_ blocks: [String]) -> String? {
        var parts: [String] = []
        for raw in blocks {
            var t = raw
            for tag in injectedTags {
                t = t.replacingOccurrences(of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if nonPromptPrefixes.contains(where: { t.hasPrefix($0) }) { return nil }
            parts.append(t)
        }
        guard var text = parts.first else { return nil }
        // Slash commands: "<command-message>x</command-message><command-name>/x</command-name><command-args>a</command-args>"
        if text.contains("<command-name>") {
            let name = capture(text, tag: "command-name") ?? ""
            let args = capture(text, tag: "command-args") ?? ""
            text = (name + (args.isEmpty ? "" : " " + args)).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return nil }
        }
        // Reply-quote markers some clients prepend ("<!-- reply 2 -->").
        text = text.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Prefer the first line that isn't a "> quoted" line.
        guard var first = lines.first(where: { !$0.hasPrefix(">") }) ?? lines.first else { return nil }
        if first.hasPrefix("❯") { first = String(first.dropFirst()).trimmingCharacters(in: .whitespaces) }
        // Remaining unknown markup (e.g. "<launch-selected-element>"): strip the tags.
        if first.hasPrefix("<") {
            let stripped = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            first = stripped.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? first
        }
        if first.count > maxPromptLength { first = String(first.prefix(maxPromptLength - 1)) + "…" }
        return first.isEmpty ? nil : first
    }

    private static func capture(_ s: String, tag: String) -> String? {
        guard let a = s.range(of: "<\(tag)>"), let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Group records (file order) into turns. Records before the first prompt form a prompt-less
    /// turn only if `includeLeading` (i.e. the records start at the beginning of the file).
    public static func turns(from records: [Record], includeLeading: Bool) -> [ReplyTurn] {
        var out: [ReplyTurn] = []
        var current: ReplyTurn?
        var texts: [String] = []
        func flush() {
            guard var t = current else { return }
            t.text = texts.joined(separator: "\n\n")
            out.append(t)
            current = nil
            texts = []
        }
        for r in records {
            switch r {
            case .prompt(let id, let text, let at):
                flush()
                current = ReplyTurn(id: id, prompt: text, promptAt: at, text: "", repliedAt: nil)
            case .text(let id, let text, let at):
                if current == nil {
                    guard includeLeading && out.isEmpty else { continue }
                    current = ReplyTurn(id: id, prompt: nil, promptAt: nil, text: "", repliedAt: nil)
                }
                texts.append(text)
                if let at { current?.repliedAt = at }
            }
        }
        flush()
        return out
    }

    /// The last `limit` turns, newest last. Turns without any reply text are dropped (slash commands
    /// with only local output, interrupted prompts), except the newest one (it may be in progress).
    public static func recent(_ turns: [ReplyTurn], limit: Int) -> [ReplyTurn] {
        var kept: [ReplyTurn] = []
        for (i, t) in turns.enumerated() where !t.isEmpty || i == turns.count - 1 { kept.append(t) }
        return Array(kept.suffix(limit))
    }

    /// Number of turns with text (excluding a trailing in-progress one) — used to decide when the
    /// backward read has found enough.
    static func completeCount(_ turns: [ReplyTurn]) -> Int {
        turns.dropLast().filter { !$0.isEmpty }.count + (turns.last.map { $0.isEmpty ? 0 : 1 } ?? 0)
    }
}

/// Session replies as returned by `ReplyReader`.
public struct SessionReplies: Equatable, Sendable {
    /// Newest last, at most `ReplyReader.maxTurns`.
    public var turns: [ReplyTurn]
    public var transcriptPath: String?
    /// Debug: bytes read from the end of the file for the last full load, and whether the last
    /// call was served from cache / incrementally.
    public var bytesScanned: UInt64
    public var source: Source
    public enum Source: String, Sendable { case full, incremental, cache }

    public init(turns: [ReplyTurn] = [], transcriptPath: String? = nil, bytesScanned: UInt64 = 0, source: Source = .full) {
        self.turns = turns; self.transcriptPath = transcriptPath; self.bytesScanned = bytesScanned; self.source = source
    }
}

/// Reads the recent replies of a session transcript off the main thread. Transcripts can be many
/// MB: the first read goes backwards from the end in `chunkSize` chunks until `maxTurns` turns with
/// text are found (or the start of the file / `maxScanBytes` is reached); the result is cached by
/// (inode, size, mtime) and refreshed incrementally (only the appended bytes) when the file grows.
public actor ReplyReader {
    public static let maxTurns = 10
    public static let defaultChunkSize = 256 * 1024
    /// Give up scanning backwards after this many bytes (huge tool outputs between prompts).
    public static let maxScanBytes: UInt64 = 32 * 1024 * 1024

    private let locator: TranscriptReader
    private let chunkSize: Int
    private let maxTurns: Int

    private struct Entry {
        var url: URL
        var inode: UInt64
        var size: UInt64
        var mtime: Date
        /// Offset just past the last complete line parsed.
        var end: UInt64
        /// Records from the start of the oldest kept turn to `end`.
        var records: [ReplyParser.Record]
        /// `records` start at the beginning of the file.
        var fromFileStart: Bool
        var bytesScanned: UInt64
    }
    private var cache: [String: Entry] = [:]

    public init(projectsDir: URL = NotchPaths.projectsDir, chunkSize: Int = ReplyReader.defaultChunkSize,
                maxTurns: Int = ReplyReader.maxTurns) {
        self.locator = TranscriptReader(projectsDir: projectsDir)
        self.chunkSize = max(64, chunkSize)
        self.maxTurns = maxTurns
    }

    /// Recent replies of a session (nil if it has no transcript yet). `transcriptPath`, when
    /// known (AppState's session), skips the lookup.
    public func replies(sessionId: String, cwd: String, transcriptPath: String? = nil) async -> SessionReplies? {
        var url: URL?
        if let p = transcriptPath, FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p) }
        if url == nil { url = await locator.transcriptURL(sessionId: sessionId, cwd: cwd) }
        guard let url else { return nil }
        return replies(key: sessionId, url: url)
    }

    /// Same, for an explicit file (tests, --dump-replies).
    public func replies(key: String, url: URL) -> SessionReplies? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast

        if var e = cache[key], e.url == url, e.inode == inode {
            if e.size == size && e.mtime == mtime {
                return result(e, source: .cache)
            }
            if size > e.size, appendIncrementally(&e, size: size) {
                e.size = size
                e.mtime = mtime
                trim(&e)
                cache[key] = e
                return result(e, source: .incremental)
            }
        }
        guard var e = loadBackwards(url: url, size: size) else { return nil }
        e.inode = inode
        e.mtime = mtime
        trim(&e)
        cache[key] = e
        return result(e, source: .full)
    }

    public func forget(_ key: String) { cache[key] = nil }
    public func retain(keys: Set<String>) { cache = cache.filter { keys.contains($0.key) } }

    // MARK: Internals

    private func result(_ e: Entry, source: SessionReplies.Source) -> SessionReplies {
        let turns = ReplyParser.turns(from: e.records, includeLeading: e.fromFileStart)
        return SessionReplies(turns: ReplyParser.recent(turns, limit: maxTurns), transcriptPath: e.url.path,
                              bytesScanned: e.bytesScanned, source: source)
    }

    /// Keep only the records of the newest `maxTurns` (+ a trailing empty) turns, starting at a prompt.
    private func trim(_ e: inout Entry) {
        var promptIdx: [Int] = []
        for (i, r) in e.records.enumerated() { if case .prompt = r { promptIdx.append(i) } }
        // Keep generously (empty turns are dropped later): 2x the limit of prompts.
        let keepPrompts = maxTurns * 2 + 1
        guard promptIdx.count > keepPrompts else { return }
        let cut = promptIdx[promptIdx.count - keepPrompts]
        e.records.removeFirst(cut)
        e.fromFileStart = false
    }

    /// Read [e.end, size) forwards and append its complete lines. false on I/O error.
    private func appendIncrementally(_ e: inout Entry, size: UInt64) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: e.url) else { return false }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: e.end)
            guard let data = try h.read(upToCount: Int(size - e.end)) else { return true }
            guard let nl = data.lastIndex(of: 0x0A) else { return true }   // no complete line yet
            let complete = data[data.startIndex..<nl]
            e.records += ReplyParser.records(lines: Self.lines(complete))
            e.end += UInt64(nl - data.startIndex + 1)
            return true
        } catch {
            return false
        }
    }

    /// Backward chunked read from the end of the file.
    private func loadBackwards(url: URL, size: UInt64) -> Entry? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // Only complete lines: find the last newline (scan the tail backwards).
        var end = size
        var records: [ReplyParser.Record] = []
        var carry = Data()          // bytes from a chunk boundary up to the first newline after it
        var pos = size
        var scanned: UInt64 = 0
        var foundEnd = false
        while pos > 0 {
            let start = pos > UInt64(chunkSize) ? pos - UInt64(chunkSize) : 0
            guard (try? h.seek(toOffset: start)) != nil,
                  let chunk = try? h.read(upToCount: Int(pos - start)) else { return nil }
            scanned += UInt64(chunk.count)
            var data = chunk
            data.append(carry)
            if !foundEnd {
                // Drop the trailing partial line (still being written).
                if let nl = data.lastIndex(of: 0x0A) {
                    end = start + UInt64(nl - data.startIndex + 1)
                    data = data[data.startIndex..<nl]
                    foundEnd = true
                } else {
                    carry = data
                    pos = start
                    if scanned > Self.maxScanBytes { break }
                    continue
                }
            }
            let body: Data
            if start > 0 {
                // The first line may continue in the previous chunk: carry it over.
                guard let nl = data.firstIndex(of: 0x0A) else {
                    carry = data
                    pos = start
                    if scanned > Self.maxScanBytes { break }
                    continue
                }
                carry = Data(data[data.startIndex..<nl])
                body = data[data.index(after: nl)...]
            } else {
                carry = Data()
                body = data
            }
            records = ReplyParser.records(lines: Self.lines(body)) + records
            pos = start
            if pos == 0 { break }
            let turns = ReplyParser.turns(from: records, includeLeading: false)
            if ReplyParser.completeCount(turns) >= maxTurns { break }
            if scanned > Self.maxScanBytes { break }
        }
        if !foundEnd { end = 0 }
        return Entry(url: url, inode: 0, size: size, mtime: .distantPast, end: end, records: records,
                     fromFileStart: pos == 0, bytesScanned: scanned)
    }

    static func lines(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }
}
