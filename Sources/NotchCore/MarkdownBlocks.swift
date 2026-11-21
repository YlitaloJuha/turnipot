import Foundation

/// Block-level Markdown for the reply reader (inline markup — bold, italic, code, links — is left
/// in the text and rendered by the view with `AttributedString(markdown:)`). Pure, self-tested.
public enum MDBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// Consecutive prose lines (line breaks kept).
    case paragraph(String)
    /// "- x" / "* x" / "1. x"; `indent` = nesting level (0 = top); `marker` "•" or "1.".
    case listItem(marker: String, indent: Int, text: String)
    /// Fenced code block (``` or ~~~); `language` from the info string.
    case code(language: String?, text: String)
    case quote(String)
    /// Pipe table. The view shows `grid` when `gridWidth` fits the column, else `records`.
    case table(MDTable)
    case rule
}

/// A parsed pipe table. Cells keep their inline markup (`records` renders it; `grid` strips
/// `**` and backticks so the monospaced columns line up).
public struct MDTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [[String]]

    public init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    var columns: Int { ([header.count] + rows.map(\.count)).max() ?? 0 }

    static func plain(_ c: String) -> String {
        c.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }

    private var widths: [Int] {
        var w = Array(repeating: 0, count: columns)
        for r in [header] + rows { for (k, c) in r.enumerated() { w[k] = max(w[k], Self.plain(c).count) } }
        return w
    }

    /// Characters per line of `grid`.
    public var gridWidth: Int {
        let w = widths
        return w.reduce(0, +) + max(0, w.count - 1) * 3
    }

    /// Aligned monospaced columns: header, a ─┼─ line, then the rows.
    public var grid: String {
        let w = widths
        func line(_ r: [String]) -> String {
            (0..<columns).map { k -> String in
                let c = k < r.count ? Self.plain(r[k]) : ""
                return c + String(repeating: " ", count: max(0, w[k] - c.count))
            }.joined(separator: " │ ").replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        var out: [String] = []
        if !header.isEmpty { out.append(line(header)); out.append(w.map { String(repeating: "─", count: $0) }.joined(separator: "─┼─")) }
        out += rows.map(line)
        return out.joined(separator: "\n")
    }

    /// One Markdown snippet per row, "**Header:** value" per non-empty cell (for narrow columns).
    public var records: [String] {
        rows.map { r in
            r.enumerated().compactMap { k, c -> String? in
                guard !c.isEmpty else { return nil }
                let h = k < header.count ? header[k] : ""
                return h.isEmpty ? c : "**\(Self.plain(h)):** \(c)"
            }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
    }
}

public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flushPara() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code.
            if let fence = fenceOpener(trimmed) {
                flushPara()
                let indent = line.prefix { $0 == " " }.count
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(fence.marker), t.allSatisfy({ $0 == fence.marker.first }) { i += 1; break }
                    // Strip up to the fence's own indentation (fences inside list items).
                    var l = Substring(lines[i])
                    var n = 0
                    while n < indent, l.first == " " { l = l.dropFirst(); n += 1 }
                    body.append(String(l))
                    i += 1
                }
                out.append(.code(language: fence.language, text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushPara(); i += 1; continue }

            // Heading.
            if let h = heading(trimmed) { flushPara(); out.append(.heading(level: h.0, text: h.1)); i += 1; continue }

            // Horizontal rule.
            if isRule(trimmed) { flushPara(); out.append(.rule); i += 1; continue }

            // Table: consecutive lines starting with "|".
            if trimmed.hasPrefix("|") {
                flushPara()
                var rows: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(.table(table(rows)))
                continue
            }

            // Quote.
            if trimmed.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    q.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            }

            // List item (+ continuation lines indented under it).
            if let item = listItem(line) {
                flushPara()
                var text = item.text
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    let t = next.trimmingCharacters(in: .whitespaces)
                    let ind = next.prefix { $0 == " " || $0 == "\t" }.count
                    if t.isEmpty || listItem(next) != nil || fenceOpener(t) != nil || heading(t) != nil || ind < 2 { break }
                    text += "\n" + t
                    i += 1
                }
                out.append(.listItem(marker: item.marker, indent: item.indent, text: text))
                continue
            }

            para.append(trimmed)
            i += 1
        }
        flushPara()
        return out
    }

    // MARK: Line classifiers

    static func fenceOpener(_ trimmed: String) -> (marker: String, language: String?)? {
        for ch in ["`", "~"] {
            let run = trimmed.prefix { String($0) == ch }.count
            if run >= 3 {
                let info = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
                // "```foo```" on one line is inline code, not a fence.
                if ch == "`" && info.contains("`") { return nil }
                let lang = info.split(separator: " ").first.map(String.init)
                return (String(repeating: ch, count: run), lang?.isEmpty == false ? lang : nil)
            }
        }
        return nil
    }

    static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var t = rest.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("#") { t.removeLast() }
        return (hashes, t.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        let s = trimmed.replacingOccurrences(of: " ", with: "")
        guard s.count >= 3, let c = s.first, "-*_".contains(c) else { return false }
        return s.allSatisfy { $0 == c }
    }

    static func listItem(_ line: String) -> (marker: String, indent: Int, text: String)? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let spaces = expanded.prefix { $0 == " " }.count
        let rest = expanded.dropFirst(spaces)
        if let f = rest.first, "-*+•".contains(f), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            // Task boxes: "- [x] done".
            if text.hasPrefix("[ ] ") { return ("☐", spaces / 2, String(text.dropFirst(4))) }
            if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return ("☑", spaces / 2, String(text.dropFirst(4))) }
            return ("•", spaces / 2, text)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let p = after.first, p == "." || p == ")", after.dropFirst().first == " " {
                return ("\(digits).", spaces / 2, after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// "| a | bb |" rows -> header + body (separator rows dropped; `\|` is a literal pipe).
    public static func table(_ rows: [String]) -> MDTable {
        func cells(_ r: String) -> [String] {
            var s = Substring(r.replacingOccurrences(of: "\\|", with: "\u{1}"))
            if s.hasPrefix("|") { s = s.dropFirst() }
            if s.hasSuffix("|") { s = s.dropLast() }
            return s.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{1}", with: "|") }
        }
        func isSep(_ c: [String]) -> Bool {
            !c.isEmpty && c.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
        }
        let parsed = rows.map(cells)
        // A header exists when the second row is the |---| separator.
        if parsed.count >= 2, isSep(parsed[1]) {
            return MDTable(header: parsed[0], rows: parsed.dropFirst(2).filter { !isSep($0) })
        }
        return MDTable(header: [], rows: parsed.filter { !isSep($0) })
    }

    /// "| a | bb |" rows -> aligned columns; the "|---|" separator becomes a ─ line.
    public static func formatTable(_ rows: [String]) -> String { table(rows).grid }
}
