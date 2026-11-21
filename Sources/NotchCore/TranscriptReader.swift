import Foundation

/// Result of reading a session transcript (~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl).
public struct TranscriptSummary: Equatable, Sendable {
    public var tokens: TokenTotals
    public var model: String?
    /// Text blocks of the latest assistant message (joined with "\n"), trimmed. nil if none yet.
    public var lastAssistantText: String?
    public var lastAssistantAt: Date?
    /// Time of the latest real user prompt (main chain; tool results / meta lines excluded).
    public var lastPromptAt: Date?
    /// Time of the latest main-chain tool_result line (a tool ran or was denied / interrupted).
    public var lastToolResultAt: Date?
    public var transcriptPath: String?
    /// Session description: the user's /rename title ("custom-title") if set, otherwise
    /// Claude Code's auto-generated "ai-title". Latest record of each kind wins.
    public var title: String?

    public init(tokens: TokenTotals = .zero, model: String? = nil, lastAssistantText: String? = nil,
                lastAssistantAt: Date? = nil, transcriptPath: String? = nil) {
        self.tokens = tokens; self.model = model; self.lastAssistantText = lastAssistantText
        self.lastAssistantAt = lastAssistantAt; self.transcriptPath = transcriptPath
    }
}

/// Incremental JSONL reader. Keeps per-session file offset + seen message ids so repeated
/// calls only parse newly appended bytes. Thread-safe (actor).
public actor TranscriptReader {

    public init(projectsDir: URL = NotchPaths.projectsDir) {
        self.projectsDir = projectsDir
    }

    private let projectsDir: URL

    /// Per-session incremental state.
    private struct Entry {
        var url: URL
        var offset: UInt64 = 0
        var fileId: UInt64 = 0           // inode; a new inode means the file was replaced
        var partial = Data()             // trailing bytes without a newline yet
        var state = ParseState()
    }

    private var entries: [String: Entry] = [:]
    private var urlCache: [String: URL] = [:]

    /// Max bytes parsed per read() call chunk (keeps memory bounded on huge transcripts).
    private static let chunkSize = 8 * 1024 * 1024
    /// Cap for lastAssistantText.
    static let maxTextLength = 4000

    /// Locate the transcript: projectsDir/<encodeProjectDirName(cwd)>/<sessionId>.jsonl,
    /// falling back to globbing projectsDir/*/<sessionId>.jsonl. Cache the result.
    public func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        if let cached = urlCache[sessionId], fm.fileExists(atPath: cached.path) { return cached }
        urlCache[sessionId] = nil
        let fileName = "\(sessionId).jsonl"
        if !cwd.isEmpty {
            let direct = projectsDir
                .appendingPathComponent(NotchPaths.encodeProjectDirName(cwd: cwd), isDirectory: true)
                .appendingPathComponent(fileName)
            if fm.fileExists(atPath: direct.path) {
                urlCache[sessionId] = direct
                return direct
            }
        }
        // Fallback: glob projectsDir/*/<sessionId>.jsonl
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: candidate.path) {
                urlCache[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }

    /// Read newly appended lines since the last call and return the cumulative summary.
    /// Only parses complete lines (keeps a partial trailing line for next time).
    /// Handles file truncation/rotation (size < offset -> reset state).
    /// Returns nil if no transcript exists yet.
    public func read(sessionId: String, cwd: String) -> TranscriptSummary? {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        var entry = entries[sessionId] ?? Entry(url: url, fileId: inode)
        if entry.url != url || entry.fileId != inode || size < entry.offset {
            entry = Entry(url: url, fileId: inode)   // moved, replaced or truncated: start over
        }
        entry.state.summary.transcriptPath = url.path

        if size > entry.offset, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: entry.offset)
                while entry.offset < size {
                    let want = Int(min(UInt64(Self.chunkSize), size - entry.offset))
                    guard let data = try handle.read(upToCount: want), !data.isEmpty else { break }
                    entry.offset += UInt64(data.count)
                    var buffer = entry.partial
                    buffer.append(data)
                    if let lastNL = buffer.lastIndex(of: 0x0A) {
                        let complete = buffer[buffer.startIndex..<lastNL]
                        entry.partial = Data(buffer[buffer.index(after: lastNL)...])
                        let text = String(decoding: complete, as: UTF8.self)
                        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                        Self.parse(lines: lines, into: &entry.state)
                    } else {
                        entry.partial = buffer
                    }
                }
            } catch {
                // Keep what we have; retry from the stored offset next time.
            }
        }
        entries[sessionId] = entry
        return entry.state.summary
    }

    /// Drop cached state for sessions that are gone.
    public func forget(sessionId: String) {
        entries[sessionId] = nil
        urlCache[sessionId] = nil
    }

    /// Keep only these session ids in the cache.
    public func retain(sessionIds: Set<String>) {
        entries = entries.filter { sessionIds.contains($0.key) }
        urlCache = urlCache.filter { sessionIds.contains($0.key) }
    }

    // MARK: Pure parsing (unit-testable)

    /// Mutable accumulation state for one transcript.
    public struct ParseState: Sendable {
        public var summary = TranscriptSummary()
        /// message.id -> usage already counted (same message can appear in several lines,
        /// one per content block; usage repeats; count each id once, latest usage wins).
        public var usageById: [String: TokenTotals] = [:]
        /// message.id whose text blocks currently make up summary.lastAssistantText.
        public var lastTextMessageId: String?
        public var customTitle: String?
        public var aiTitle: String?
        public init() {}
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func int(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let i = v as? Int { return i }
        return 0
    }

    /// Parse complete JSONL lines into `state`. Lines with type == "assistant" carry
    /// message.id, message.model, message.usage {input_tokens, cache_creation_input_tokens,
    /// cache_read_input_tokens, output_tokens}, message.content [{type:"text", text}], timestamp (ISO8601).
    /// Ignores malformed lines.
    public static func parse(lines: [Substring], into state: inout ParseState) {
        for line in lines {
            // Title records: {"type":"custom-title","customTitle":...} / {"type":"ai-title","aiTitle":...}
            if line.contains("-title\""), parseTitle(line, into: &state) { continue }
            // Compaction ({"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":N}}):
            // the context shrinks right away; the next main-chain assistant message refines it.
            if line.contains("\"compact_boundary\""), parseCompactBoundary(line, into: &state) { continue }
            // Real user prompts: only their time is needed (the row's "last interaction").
            // Anything else (e.g. an assistant line whose tool input nests a "type":"user" object)
            // falls through to the assistant parsing below.
            if line.contains("\"type\":\"user\""), !line.contains("\"type\":\"tool_result\""),
               case .prompt(_, _, let at)? = ReplyParser.record(line) {
                if let at { state.summary.lastPromptAt = at }
                continue
            }
            // Tool results (main chain): only their time is needed (TerminalDialogGuard progress).
            if line.contains("\"tool_result\""), line.contains("\"type\":\"user\""),
               parseToolResult(line, into: &state) { continue }
            // Cheap pre-filter: every assistant line contains this literal.
            guard line.contains("\"assistant\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }

            let isSidechain = obj["isSidechain"] as? Bool ?? false
            let messageId = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
            let model = message["model"] as? String
            let isSynthetic = model == "<synthetic>"

            // Usage: count each message id once; latest usage for that id wins.
            if let u = message["usage"] as? [String: Any] {
                let input = int(u["input_tokens"])
                let cc = int(u["cache_creation_input_tokens"])
                let cr = int(u["cache_read_input_tokens"])
                var t = TokenTotals(input: input, cacheCreation: cc, cacheRead: cr,
                                    output: int(u["output_tokens"]), lastContext: 0)
                let context = input + cc + cr
                t.lastContext = context
                let old = state.usageById[messageId] ?? .zero
                state.usageById[messageId] = t
                var s = state.summary.tokens
                s.input += t.input - old.input
                s.cacheCreation += t.cacheCreation - old.cacheCreation
                s.cacheRead += t.cacheRead - old.cacheRead
                s.output += t.output - old.output
                if !isSidechain && !isSynthetic && context > 0 {
                    s.lastContext = context
                }
                state.summary.tokens = s
            }

            guard !isSidechain else { continue }

            if let model, !model.isEmpty, !isSynthetic { state.summary.model = model }

            // Text blocks of this line (assistant messages are often split one block per line).
            var texts: [String] = []
            if let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "text" {
                    if let t = block["text"] as? String { texts.append(t) }
                }
            } else if let s = message["content"] as? String {
                texts.append(s)
            }
            let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                if state.lastTextMessageId == messageId, let prev = state.summary.lastAssistantText {
                    state.summary.lastAssistantText = capped(prev + "\n" + joined)
                } else {
                    state.summary.lastAssistantText = capped(joined)
                    state.lastTextMessageId = messageId
                }
            }
            if let ts = obj["timestamp"] as? String, let d = parseDate(ts) {
                state.summary.lastAssistantAt = d
            }
        }
    }

    /// Returns true if the line was a title record.
    private static func parseTitle(_ line: Substring, into state: inout ParseState) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return false }
        func clean(_ v: Any?) -> String? {
            guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return String(s.prefix(120))
        }
        switch type {
        case "custom-title": if let t = clean(obj["customTitle"]) { state.customTitle = t }
        case "ai-title": if let t = clean(obj["aiTitle"]) { state.aiTitle = t }
        default: return false
        }
        state.summary.title = state.customTitle ?? state.aiTitle
        return true
    }

    /// Returns true if the line was a user line (tool results recorded when on the main chain);
    /// false for anything else (e.g. an assistant line whose tool input nests such an object).
    private static func parseToolResult(_ line: Substring, into state: inout ParseState) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "user" else { return false }
        if obj["isSidechain"] as? Bool == true { return true }
        let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        guard content.contains(where: { $0["type"] as? String == "tool_result" }),
              let ts = obj["timestamp"] as? String, let d = parseDate(ts) else { return true }
        if d > (state.summary.lastToolResultAt ?? .distantPast) { state.summary.lastToolResultAt = d }
        return true
    }

    /// Returns true if the line was a main-chain compact boundary.
    private static func parseCompactBoundary(_ line: Substring, into state: inout ParseState) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "system", obj["subtype"] as? String == "compact_boundary" else { return false }
        if obj["isSidechain"] as? Bool == true { return true }
        let meta = obj["compactMetadata"] as? [String: Any]
        let post = int(meta?["postTokens"])
        if post > 0 { state.summary.tokens.lastContext = post }
        return true
    }

    private static func capped(_ s: String) -> String {
        s.count > maxTextLength ? String(s.prefix(maxTextLength)) + "…" : s
    }
}
