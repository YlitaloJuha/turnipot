import Foundation

/// JSON value that keeps object key order and formats like Python's
/// `json.dumps(indent=2, ensure_ascii=False)`, so the app edits ~/.claude/settings.json exactly
/// like scripts/install-hook.sh does (same order, same layout, nothing else touched).
public indirect enum OrderedJSON: Equatable, Sendable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// Kept as its source text (integers) or Python's float repr.
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> OrderedJSON? {
        if case .object(let kv) = self { return kv.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    // MARK: Parse

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ text: String) throws -> OrderedJSON {
        var p = Parser(Array(text.unicodeScalars))
        p.skipWhitespace()
        let v = try p.value()
        p.skipWhitespace()
        guard p.atEnd else { throw ParseError(description: "extra data after the JSON value") }
        return v
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }
        var atEnd: Bool { i >= s.count }

        mutating func skipWhitespace() {
            while i < s.count, [" ", "\n", "\r", "\t"].contains(s[i]) { i += 1 }
        }

        func fail(_ what: String) -> ParseError { ParseError(description: "\(what) at offset \(i)") }

        mutating func value() throws -> OrderedJSON {
            guard i < s.count else { throw fail("unexpected end") }
            switch s[i] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .string(try string())
            case "t": try literal("true"); return .bool(true)
            case "f": try literal("false"); return .bool(false)
            case "n": try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            for c in word.unicodeScalars {
                guard i < s.count, s[i] == c else { throw fail("invalid literal") }
                i += 1
            }
        }

        mutating func object() throws -> OrderedJSON {
            i += 1
            var kv: [(String, OrderedJSON)] = []
            skipWhitespace()
            if i < s.count, s[i] == "}" { i += 1; return .object(kv) }
            while true {
                skipWhitespace()
                guard i < s.count, s[i] == "\"" else { throw fail("expected a key") }
                let k = try string()
                skipWhitespace()
                guard i < s.count, s[i] == ":" else { throw fail("expected ':'") }
                i += 1
                skipWhitespace()
                let v = try value()
                // Like Python's dict: a repeated key keeps its first position, the last value wins.
                if let j = kv.firstIndex(where: { $0.0 == k }) { kv[j].1 = v } else { kv.append((k, v)) }
                skipWhitespace()
                guard i < s.count else { throw fail("unterminated object") }
                if s[i] == "," { i += 1; continue }
                if s[i] == "}" { i += 1; return .object(kv) }
                throw fail("expected ',' or '}'")
            }
        }

        mutating func array() throws -> OrderedJSON {
            i += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if i < s.count, s[i] == "]" { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard i < s.count else { throw fail("unterminated array") }
                if s[i] == "," { i += 1; continue }
                if s[i] == "]" { i += 1; return .array(items) }
                throw fail("expected ',' or ']'")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= s.count else { throw fail("bad \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                guard let d = Int(String(s[i]), radix: 16) else { throw fail("bad \\u escape") }
                v = v * 16 + UInt32(d)
                i += 1
            }
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while true {
                guard i < s.count else { throw fail("unterminated string") }
                let c = s[i]
                i += 1
                if c == "\"" { return String(out) }
                if c.value < 0x20 { throw fail("control character in string") }
                guard c == "\\" else { out.append(c); continue }
                guard i < s.count else { throw fail("unterminated escape") }
                let e = s[i]
                i += 1
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    var v = try hex4()
                    if (0xD800...0xDBFF).contains(v), i + 6 <= s.count, s[i] == "\\", s[i + 1] == "u" {
                        i += 2
                        let lo = try hex4()
                        guard (0xDC00...0xDFFF).contains(lo) else { throw fail("bad surrogate pair") }
                        v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                    }
                    guard let u = Unicode.Scalar(v) else { throw fail("lone surrogate") }
                    out.append(u)
                default: throw fail("bad escape")
                }
            }
        }

        mutating func number() throws -> OrderedJSON {
            let start = i
            if i < s.count, s[i] == "-" { i += 1 }
            var isInt = true
            while i < s.count, ("0"..."9").contains(s[i]) || [".", "e", "E", "+", "-"].contains(s[i]) {
                if [".", "e", "E"].contains(s[i]) { isInt = false }
                i += 1
            }
            var str = String.UnicodeScalarView()
            str.append(contentsOf: s[start..<i])
            let raw = String(str)
            if isInt, raw.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil { return .number(raw) }
            guard raw.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
                  let d = Double(raw), d.isFinite else { throw fail("invalid number") }
            return .number(Self.pythonFloat(d))
        }

        /// Python's repr(float) for the common cases ("1.5", "100000.0", "1e-05", "1e+16").
        static func pythonFloat(_ d: Double) -> String {
            var t = "\(d)"
            if let e = t.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                var mant = String(t[..<e])
                var exp = String(t[t.index(after: e)...])
                if mant.hasSuffix(".0") { mant.removeLast(2) }
                let neg = exp.hasPrefix("-")
                exp = exp.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                if exp.count < 2 { exp = "0" + exp }
                t = mant + "e" + (neg ? "-" : "+") + exp
            }
            return t
        }
    }

    // MARK: Serialize (json.dumps(indent=2, ensure_ascii=False))

    public func serialized(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, level: 0, indent: indent)
        return out
    }

    private func write(into out: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: indent * (level + 1))
        let closePad = String(repeating: " ", count: indent * level)
        switch self {
        case .object(let kv):
            if kv.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, (k, v)) in kv.enumerated() {
                out += pad + Self.quote(k) + ": "
                v.write(into: &out, level: level + 1, indent: indent)
                out += n == kv.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, v) in items.enumerated() {
                out += pad
                v.write(into: &out, level: level + 1, indent: indent)
                out += n == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .string(let s): out += Self.quote(s)
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

/// Registering turnipot-hook as Claude Code's `PermissionRequest` hook in ~/.claude/settings.json:
/// the same rules as scripts/install-hook.sh (keep: matcher "*", timeout 600 s, replaces earlier
/// turnipot-hook / notch-hook entries by executable name, keeps everything else, backup first,
/// atomic replace through a symlinked settings.json).
public enum HookSettings {
    /// Executable names recognised as ours (current name, and the hook from before the rename).
    public static let ourNames: Set<String> = ["turnipot-hook", "notch-hook"]
    public static let timeout = 600

    public struct Plan: Equatable, Sendable {
        /// The new settings.json text (with a trailing newline).
        public var output: String
        /// Our existing entries that are replaced (install) or removed (uninstall).
        public var removed: Int
        /// Hook commands of ours currently registered (for "already installed").
        public var existingCommands: [String]
        /// Other PermissionRequest hook commands that stay as they are.
        public var otherCommands: [String]
        /// Whether the settings change at all (semantically).
        public var changes: Bool
    }

    public enum InstallError: Error, CustomStringConvertible {
        case invalidJSON(String)
        case notAnObject
        case io(String)
        public var description: String {
            switch self {
            case .invalidJSON(let m): return "settings.json isn't valid JSON (\(m))"
            case .notAnObject: return "settings.json is not a JSON object"
            case .io(let m): return m
            }
        }
    }

    /// shlex.quote: unchanged when only [A-Za-z0-9_@%+=:,./-], else single-quoted.
    public static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = s.unicodeScalars.allSatisfy { u in
            (u.value < 128 && (CharacterSet.alphanumerics.contains(u) || "_@%+=:,./-".unicodeScalars.contains(u)))
        }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// First word of a command line, like Python's shlex.split(cmd)[0] (posix mode); nil if
    /// the quoting is unbalanced (the caller then splits on whitespace, as the script does).
    public static func firstWord(_ cmd: String) -> String? {
        var word = ""
        var started = false
        var it = Array(cmd.unicodeScalars)[...]
        while let c = it.first, c == " " || c == "\t" || c == "\n" || c == "\r" { it = it.dropFirst() }
        while let c = it.first {
            it = it.dropFirst()
            switch c {
            case " ", "\t", "\n", "\r":
                return word
            case "'":
                started = true
                guard let end = it.firstIndex(of: "'") else { return nil }
                word.unicodeScalars.append(contentsOf: it[it.startIndex..<end])
                it = it[it.index(after: end)...]
            case "\"":
                started = true
                var closed = false
                while let d = it.first {
                    it = it.dropFirst()
                    if d == "\"" { closed = true; break }
                    // shlex (posix): inside "…" only \" and \\ are escapes.
                    if d == "\\", let n = it.first, n == "\\" || n == "\"" {
                        it = it.dropFirst()
                        word.unicodeScalars.append(n)
                        continue
                    }
                    word.unicodeScalars.append(d)
                }
                if !closed { return nil }
            case "\\":
                started = true
                guard let n = it.first else { return nil }
                it = it.dropFirst()
                word.unicodeScalars.append(n)
            default:
                started = true
                word.unicodeScalars.append(c)
            }
        }
        return started ? word : ""
    }

    /// Is this hook entry (`{"type":"command","command":...}`) ours? Matched on the executable's
    /// file name only, so an unrelated hook in a folder like "claude-notch-sounds" is never touched.
    public static func isOurs(_ hook: OrderedJSON) -> Bool {
        guard case .object = hook else { return false }
        let cmd: String
        switch hook["command"] {
        case .string(let s)?: cmd = s
        case .number(let n)?: cmd = n
        case .bool(let b)?: cmd = b ? "True" : "False"
        default: cmd = ""
        }
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = firstWord(trimmed) ?? trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first.map(String.init)
        guard let first, !first.isEmpty else { return false }
        return ourNames.contains((first as NSString).lastPathComponent)
    }

    /// What install (hookPath non-nil) or uninstall (hookPath nil) does to `settingsText`
    /// (nil / blank = no file yet).
    public static func plan(settingsText: String?, hookPath: String?) throws -> Plan {
        var root: [(String, OrderedJSON)] = []
        var original: OrderedJSON = .object([])
        if let text = settingsText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { original = try OrderedJSON.parse(text) } catch let e as OrderedJSON.ParseError {
                throw InstallError.invalidJSON(e.description)
            }
            guard case .object(let kv) = original else { throw InstallError.notAnObject }
            root = kv
        }
        func get(_ kv: [(String, OrderedJSON)], _ k: String) -> OrderedJSON? { kv.first { $0.0 == k }?.1 }
        func set(_ kv: inout [(String, OrderedJSON)], _ k: String, _ v: OrderedJSON?) {
            if let j = kv.firstIndex(where: { $0.0 == k }) {
                if let v { kv[j].1 = v } else { kv.remove(at: j) }
            } else if let v { kv.append((k, v)) }
        }

        // hooks = data.setdefault("hooks", {})
        var hooksKV: [(String, OrderedJSON)] = []
        if let h = get(root, "hooks") {
            guard case .object(let kv) = h else { throw InstallError.invalidJSON("\"hooks\" is not an object") }
            hooksKV = kv
        } else {
            set(&root, "hooks", .object([]))
        }
        var groups: [OrderedJSON] = []
        if let g = get(hooksKV, "PermissionRequest") {
            guard case .array(let a) = g else { throw InstallError.invalidJSON("\"PermissionRequest\" is not a list") }
            groups = a
        }

        var removed = 0
        var existing: [String] = []
        var others: [String] = []
        var cleaned: [OrderedJSON] = []
        for g in groups {
            guard case .object(var gkv) = g else { cleaned.append(g); continue }
            let inner: [OrderedJSON]
            if case .array(let a)? = get(gkv, "hooks") { inner = a } else { inner = [] }
            var kept: [OrderedJSON] = []
            for h in inner {
                if isOurs(h) {
                    removed += 1
                    existing.append(h["command"]?.stringValue ?? "")
                } else {
                    kept.append(h)
                    if let c = h["command"]?.stringValue { others.append(c) }
                }
            }
            if !kept.isEmpty {
                set(&gkv, "hooks", .array(kept))
                cleaned.append(.object(gkv))
            } else if inner.isEmpty {
                // Python: `elif not g.get("hooks")` keeps groups whose hooks are missing / empty / falsy.
                cleaned.append(g)
            }
        }
        if let hookPath {
            cleaned.append(.object([
                ("matcher", .string("*")),
                ("hooks", .array([.object([("type", .string("command")),
                                           ("command", .string(shellQuote(hookPath))),
                                           ("timeout", .number(String(timeout)))])])),
            ]))
        }
        if cleaned.isEmpty { set(&hooksKV, "PermissionRequest", nil) } else { set(&hooksKV, "PermissionRequest", .array(cleaned)) }
        if hooksKV.isEmpty { set(&root, "hooks", nil) } else { set(&root, "hooks", .object(hooksKV)) }

        let result = OrderedJSON.object(root)
        return Plan(output: result.serialized() + "\n", removed: removed, existingCommands: existing,
                    otherCommands: others, changes: result != original)
    }

    public struct Applied: Equatable, Sendable {
        public var plan: Plan
        /// Backup of the previous file (nil when there was none or nothing changed).
        public var backupPath: String?
        public var wrote: Bool
    }

    /// Backup name like the script's: settings.json.bak-YYYYmmdd-HHMMSS-<pid>.
    public static func backupPath(for settingsPath: String, now: Date, pid: Int32 = getpid()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(settingsPath).bak-\(f.string(from: now))-\(pid)"
    }

    /// Install (hookPath) or uninstall (nil) into `settingsPath`. Nothing is written when the
    /// settings wouldn't change. Otherwise: back up the current file next to it, then atomically
    /// replace the real file (a symlinked settings.json keeps its link), preserving its mode.
    public static func apply(settingsPath: String, hookPath: String?, now: Date = Date()) throws -> Applied {
        let fm = FileManager.default
        let real = (settingsPath as NSString).resolvingSymlinksInPath
        let exists = fm.fileExists(atPath: real)
        var text: String?
        if exists {
            guard let data = fm.contents(atPath: real) else { throw InstallError.io("Can't read \(settingsPath)") }
            text = String(decoding: data, as: UTF8.self)
        }
        let plan = try plan(settingsText: text, hookPath: hookPath)
        guard plan.changes || !exists && hookPath != nil else { return Applied(plan: plan, backupPath: nil, wrote: false) }

        var backup: String?
        var mode: Int = 0o644
        if exists {
            let attrs = try? fm.attributesOfItem(atPath: real)
            mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let b = backupPath(for: settingsPath, now: now)
            guard fm.createFile(atPath: b, contents: fm.contents(atPath: real),
                                attributes: [.posixPermissions: mode]) else {
                throw InstallError.io("Can't write the backup \(b)")
            }
            backup = b
        }
        let dir = (real as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch { throw InstallError.io("Can't create \(dir)") }
        let tmp = (dir as NSString).appendingPathComponent(".settings.\(UUID().uuidString.prefix(8)).tmp")
        guard fm.createFile(atPath: tmp, contents: Data(plan.output.utf8), attributes: [.posixPermissions: mode]) else {
            throw InstallError.io("Can't write in \(dir)")
        }
        if rename(tmp, real) != 0 {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            throw InstallError.io("Can't replace \(settingsPath): \(err)")
        }
        return Applied(plan: plan, backupPath: backup, wrote: true)
    }
}
