import Foundation

// "Missed sessions": finished sessions the user hasn't looked at yet, "waiting for you"
// classification, the panel's sort order, the collapsed pill's badge text, the agent sprout
// pips and the "While you were away" summary. Pure functions + value types; AppState owns the
// state (see AppState's "Unseen" section).

/// Why an unseen session wants attention.
public enum UnseenKind: String, Equatable, Sendable {
    /// Claude finished (busy -> idle) and the user hasn't looked yet.
    case done
    /// Finished, and Claude's last message ends with a question.
    case waiting
}

/// A finished session the user hasn't seen yet (kind is derived from the session's current
/// last assistant text, so a transcript read that lands after the busy -> idle flip still counts).
public struct UnseenItem: Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var finishedAt: Date
    public var kind: UnseenKind

    public init(sessionId: String, finishedAt: Date, kind: UnseenKind) {
        self.sessionId = sessionId; self.finishedAt = finishedAt; self.kind = kind
    }
}

// MARK: - Last sentence / question detection

public enum AttentionText {
    /// The last sentence of an assistant message, cleaned for a one-line preview: fenced code
    /// blocks, markdown markers (headings, list bullets, quotes, emphasis, inline code, links)
    /// and surrounding quotes are removed; newlines collapse to spaces. nil if nothing is left.
    public static func lastSentence(_ text: String?) -> String? {
        guard let line = lastProseLine(text) else { return nil }
        // A trailing "🚀" / "✅" alone is not a sentence.
        let sentences = splitSentences(line).filter { $0.contains { $0.isLetter || $0.isNumber } }
        guard var last = sentences.last else { return nil }
        last = last.trimmingCharacters(in: .whitespaces)
        last = trimQuotes(last)
        return last.isEmpty ? nil : last
    }

    /// True when the last non-empty sentence ends with "?" (ignoring trailing whitespace,
    /// markdown, code fences, closing quotes / brackets and emoji).
    public static func endsWithQuestion(_ text: String?) -> Bool {
        guard let s = lastSentence(text) else { return false }
        let stripped = stripTrailingDecoration(s)
        return stripped.hasSuffix("?") || stripped.hasSuffix("？")
    }

    public static func classify(_ text: String?) -> UnseenKind {
        endsWithQuestion(text) ? .waiting : .done
    }

    // MARK: helpers

    /// Last non-empty line outside fenced code blocks, with markdown markers removed.
    static func lastProseLine(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var inFence = false
        var prose: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            let cleaned = cleanMarkdown(t)
            if !cleaned.isEmpty { prose.append(cleaned) }
        }
        return prose.last
    }

    /// Strip line-level and inline markdown from one line.
    static func cleanMarkdown(_ line: String) -> String {
        var s = line
        // Table separator rows ("|---|:--:|") carry no prose.
        if s.allSatisfy({ "|-: ".contains($0) }) { return "" }
        // Leading markers: headings, quotes, bullets, numbered items, task boxes.
        let leading = [#"^#{1,6}\s+"#, #"^(>\s*)+"#, #"^[-*+•]\s+"#, #"^\d+[.)]\s+"#, #"^\[[ xX]\]\s+"#]
        var changed = true
        while changed {
            changed = false
            for p in leading {
                if let r = s.range(of: p, options: .regularExpression), !r.isEmpty {
                    s.removeSubrange(r); changed = true
                }
            }
        }
        // Table rows: keep the cell text.
        if s.hasPrefix("|") {
            s = s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
        // Links / images: [text](url) -> text.
        s = s.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Emphasis / inline code markers.
        for m in ["**", "__", "`"] { s = s.replacingOccurrences(of: m, with: "") }
        s = s.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*]+?)(?<!\s)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w_])_(?!\s)([^_]+?)(?<!\s)_(?![\w_])"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Split at ". ", "! ", "? " (also "…" / "?!") when the next word doesn't start lowercase
    /// (so "e.g. foo" and version numbers like "0.1.2" stay intact).
    static func splitSentences(_ line: String) -> [String] {
        let chars = Array(line)
        var out: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if ".!?…？！".contains(c) {
                // Consume a run of terminal punctuation + closing quotes / brackets.
                var j = i + 1
                while j < chars.count, ".!?…？！\"'”’)]»".contains(chars[j]) { j += 1 }
                if j < chars.count, chars[j].isWhitespace {
                    var k = j
                    while k < chars.count, chars[k].isWhitespace { k += 1 }
                    if k < chars.count, !chars[k].isLowercase {
                        out.append(String(chars[start..<j]))
                        start = k
                        i = k
                        continue
                    }
                }
                i = j
                continue
            }
            i += 1
        }
        if start < chars.count { out.append(String(chars[start...])) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Remove surrounding quote characters.
    static func trimQuotes(_ s: String) -> String {
        let quotes: Set<Character> = ["\"", "“", "”", "'", "‘", "’", "«", "»"]
        var t = Substring(s)
        while let f = t.first, quotes.contains(f) { t = t.dropFirst() }
        while let l = t.last, quotes.contains(l) { t = t.dropLast() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Drop trailing whitespace, quotes, closing brackets, emoji and other symbols.
    static func stripTrailingDecoration(_ s: String) -> String {
        var t = Substring(s)
        while let l = t.last {
            if l.isWhitespace || "\"'”’»)]*_`~".contains(l) || isEmojiOrSymbol(l) { t = t.dropLast() } else { break }
        }
        return String(t)
    }

    static func isEmojiOrSymbol(_ c: Character) -> Bool {
        if c.isLetter || c.isNumber || c.isPunctuation { return false }
        return c.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0xFF }
            || c.unicodeScalars.allSatisfy { $0.properties.generalCategory == .otherSymbol
                || $0.properties.generalCategory == .nonspacingMark
                || $0.properties.generalCategory == .enclosingMark
                || $0.properties.generalCategory == .format
                || $0.value == 0xFE0F }
    }
}

// MARK: - Panel order

public enum AttentionRules {
    /// Order of the expanded panel: highlighted (unseen) sessions first — waiting before done,
    /// newest finish first — then everything else in its incoming order.
    public static func panelOrder(_ sessions: [ClaudeSession], highlighted: [String: UnseenItem]) -> [ClaudeSession] {
        let top = sessions.compactMap { s in highlighted[s.sessionId].map { (s, $0) } }
            .sorted { a, b in
                if a.1.kind != b.1.kind { return a.1.kind == .waiting }
                if a.1.finishedAt != b.1.finishedAt { return a.1.finishedAt > b.1.finishedAt }
                return a.0.startedAt < b.0.startedAt
            }
            .map(\.0)
        let rest = sessions.filter { highlighted[$0.sessionId] == nil }
        return top + rest
    }
}

// MARK: - Collapsed pill badge

/// The collapsed pill's "unseen" badge: an orange dot + "2 done", amber "1 waiting", or both.
public struct PillBadge: Equatable, Sendable {
    public var text: String
    /// Amber dot/text (something is waiting for you); orange otherwise.
    public var waiting: Bool

    public init(text: String, waiting: Bool) { self.text = text; self.waiting = waiting }

    /// Preferred texts, most informative first; the last one is the most compact ("N new").
    public static func candidates(waiting: Int, done: Int) -> [PillBadge] {
        let w = max(0, waiting), d = max(0, done)
        guard w + d > 0 else { return [] }
        var out: [PillBadge] = []
        if w > 0 && d > 0 { out.append(PillBadge(text: "\(w) waiting · \(d) done", waiting: true)) }
        else if w > 0 { out.append(PillBadge(text: "\(w) waiting", waiting: true)) }
        else { out.append(PillBadge(text: "\(d) done", waiting: false)) }
        let compact = PillBadge(text: "\(w + d) new", waiting: w > 0)
        if !out.contains(compact) { out.append(compact) }
        return out
    }

    /// First candidate that `fits`, else the most compact one. nil when nothing is unseen.
    public static func choose(waiting: Int, done: Int, fits: (PillBadge) -> Bool) -> PillBadge? {
        let c = candidates(waiting: waiting, done: done)
        return c.first(where: fits) ?? c.last
    }
}

// MARK: - Agent sprout pips

public enum AgentPips {
    /// At most this many sprouts; the rest is "+N".
    public static let maxPips = 3

    /// Sprouts to draw for `running` running subagents, and the "+N" overflow (0 = none).
    public static func layout(running: Int) -> (pips: Int, overflow: Int) {
        let n = max(0, running)
        return (min(n, maxPips), max(0, n - maxPips))
    }
}

// MARK: - While you were away

public struct AwaySummary: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case asked     // a permission request came in ("asked you something")
        case waiting   // finished with a question
        case done      // finished
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String { sessionId }
        public var sessionId: String
        public var kind: Kind
        /// When it finished / asked.
        public var at: Date

        public init(sessionId: String, kind: Kind, at: Date) {
            self.sessionId = sessionId; self.kind = kind; self.at = at
        }
    }

    public var awaySince: Date
    public var returnedAt: Date
    public var items: [Item]

    public init(awaySince: Date, returnedAt: Date, items: [Item]) {
        self.awaySince = awaySince; self.returnedAt = returnedAt; self.items = items
    }

    /// Rows shown before "+N more".
    public static let maxVisible = 4

    public var awayDuration: TimeInterval { max(0, returnedAt.timeIntervalSince(awaySince)) }
    public var visibleItems: [Item] { Array(items.prefix(Self.maxVisible)) }
    public var moreCount: Int { max(0, items.count - Self.maxVisible) }

    static func rank(_ k: Kind) -> Int { k == .asked ? 0 : k == .waiting ? 1 : 2 }

    /// Items for one away period: still-unseen sessions that finished while away, plus
    /// permission requests that came in while away. One item per (live) session, the most urgent
    /// kind wins (asked > waiting > done). Sorted by urgency, newest first. nil if empty.
    public static func build(awaySince: Date, returnedAt: Date, unseen: [UnseenItem],
                             asked: [String: Date], liveSessionIds: Set<String>) -> AwaySummary? {
        var best: [String: Item] = [:]
        func offer(_ item: Item) {
            guard liveSessionIds.contains(item.sessionId), item.at >= awaySince, item.at <= returnedAt else { return }
            if let cur = best[item.sessionId] {
                let a = rank(item.kind), b = rank(cur.kind)
                if a < b || (a == b && item.at > cur.at) { best[item.sessionId] = item }
            } else {
                best[item.sessionId] = item
            }
        }
        for u in unseen { offer(Item(sessionId: u.sessionId, kind: u.kind == .waiting ? .waiting : .done, at: u.finishedAt)) }
        for (sid, at) in asked { offer(Item(sessionId: sid, kind: .asked, at: at)) }
        guard !best.isEmpty else { return nil }
        return AwaySummary(awaySince: awaySince, returnedAt: returnedAt, items: sorted(Array(best.values)))
    }

    static func sorted(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            let ra = rank(a.kind), rb = rank(b.kind)
            if ra != rb { return ra < rb }
            if a.at != b.at { return a.at > b.at }
            return a.sessionId < b.sessionId
        }
    }

    /// A summary still on screen absorbs a newer one (newer item per session wins); the away
    /// period shown is the newer one.
    public func merged(with newer: AwaySummary) -> AwaySummary {
        var bySession = Dictionary(items.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        for i in newer.items { bySession[i.sessionId] = i }
        return AwaySummary(awaySince: newer.awaySince, returnedAt: newer.returnedAt,
                           items: Self.sorted(Array(bySession.values)))
    }

    /// Without the given session's item (nil when nothing is left).
    public func removing(sessionId: String) -> AwaySummary? {
        let rest = items.filter { $0.sessionId != sessionId }
        return rest.isEmpty ? nil : AwaySummary(awaySince: awaySince, returnedAt: returnedAt, items: rest)
    }
}
