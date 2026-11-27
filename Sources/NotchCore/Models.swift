import Foundation

// MARK: - Constants / paths

public enum NotchConstants {
    /// Usage percent at or above which the island shows the near-limit state / sweat mascot.
    public static let nearLimitPercent: Int = 85
    /// The hook gives up after this many seconds (and exits 0 silently).
    public static let hookTimeout: TimeInterval = 60
    /// The app answers "ask" itself slightly before the hook times out.
    public static let permissionUITimeout: TimeInterval = 55
    /// Questions (AskUserQuestion) and plans (ExitPlanMode) take longer to read: the hook waits
    /// 570 s for them (install-hook.sh registers a 600 s hook timeout); the app gives up first.
    public static let questionUITimeout: TimeInterval = 565
    /// How long the "session finished" drop-down stays visible.
    public static let finishedDisplayDuration: TimeInterval = 6
    /// Usage poll interval.
    public static let usagePollInterval: TimeInterval = 120
    /// Session dir fallback poll interval.
    public static let sessionPollInterval: TimeInterval = 2
    public static let vscodiumBundleId = "com.vscodium"
    /// Claude Desktop (its Code tab runs Claude Code sessions with entrypoint "claude-desktop").
    public static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"
    /// Installed location of Claude Desktop; used to recognise its process tree.
    public static let claudeDesktopAppPath = "/Applications/Claude.app"
}

public enum NotchPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// ~/.claude/sessions
    public static var sessionsDir: URL { home.appendingPathComponent(".claude/sessions", isDirectory: true) }
    /// ~/.claude/projects
    public static var projectsDir: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
    /// ~/Library/Application Support/Turnipot
    public static var runtimeDir: URL {
        home.appendingPathComponent("Library/Application Support/Turnipot", isDirectory: true)
    }
    /// Claude Desktop's Code-tab session records:
    /// ~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<uuid>.json
    public static var claudeDesktopSessionsDir: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }
    /// ~/Library/Application Support/Turnipot/app.sock (permission hook -> app)
    public static var appSocket: URL { runtimeDir.appendingPathComponent("app.sock") }
    /// Prefix/suffix of VSCodium extension sockets: vscode-<pid>.sock
    public static let vscodeSocketPrefix = "vscode-"
    public static let vscodeSocketSuffix = ".sock"

    /// Encode a cwd the way Claude Code names project dirs:
    /// every character that is not [A-Za-z0-9] becomes "-".
    /// "/Users/x/Work Projects/acme-api" -> "-Users-x-Work-Projects-acme-api"
    /// "/Users/x/.claude" -> "-Users-x--claude"  (verified on this machine)
    public static func encodeProjectDirName(cwd: String) -> String {
        String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    public static func ensureRuntimeDir() {
        try? FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
    }
}

// MARK: - Generic JSON

/// Lossless JSON value used for tool inputs / raw hook payloads.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// From a JSONSerialization value (NSNumber booleans become .bool).
    public init(any v: Any?) {
        switch v {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    /// Objects: every key both sides have holds the same value (Claude Code adds keys to some
    /// tool inputs before the hook sees them, e.g. ExitPlanMode's plan / planFilePath).
    /// Anything else: equal.
    public func sharesValues(with other: JSONValue) -> Bool {
        guard case .object(let a) = self, case .object(let b) = other else { return self == other }
        return a.allSatisfy { k, v in b[k].map { $0 == v } ?? true }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Compact single-line JSON (sorted keys).
    public var compactString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(self) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Sessions

public enum SessionStatus: String, Codable, Equatable, Sendable {
    case idle, busy, unknown
}

/// Raw contents of ~/.claude/sessions/<pid>.json (only the fields we use; all optional except pid/sessionId).
public struct SessionFile: Decodable, Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String?
    public var startedAt: Double?        // epoch ms
    public var version: String?
    public var kind: String?
    public var entrypoint: String?
    public var name: String?
    public var status: String?           // "idle" | "busy"
    public var updatedAt: Double?        // epoch ms
    public var statusUpdatedAt: Double?  // epoch ms
    public var messagingSocketPath: String?

    public init(pid: Int32, sessionId: String, cwd: String? = nil, startedAt: Double? = nil,
                version: String? = nil, kind: String? = nil, entrypoint: String? = nil,
                name: String? = nil, status: String? = nil, updatedAt: Double? = nil,
                statusUpdatedAt: Double? = nil, messagingSocketPath: String? = nil) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd; self.startedAt = startedAt
        self.version = version; self.kind = kind; self.entrypoint = entrypoint; self.name = name
        self.status = status; self.updatedAt = updatedAt; self.statusUpdatedAt = statusUpdatedAt
        self.messagingSocketPath = messagingSocketPath
    }
}

/// Token usage summed over all (deduped) assistant messages of a transcript.
public struct TokenTotals: Codable, Equatable, Hashable, Sendable {
    public var input: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var output: Int
    /// Context size of the most recent assistant message (input + cacheCreation + cacheRead).
    public var lastContext: Int

    public init(input: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, output: Int = 0, lastContext: Int = 0) {
        self.input = input; self.cacheCreation = cacheCreation; self.cacheRead = cacheRead
        self.output = output; self.lastContext = lastContext
    }

    public static let zero = TokenTotals()

    /// All tokens processed (input + cache creation + cache read + output).
    public var total: Int { input + cacheCreation + cacheRead + output }

    public static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input, cacheCreation: a.cacheCreation + b.cacheCreation,
                    cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output,
                    lastContext: max(a.lastContext, b.lastContext))
    }

    /// "12.3k", "1.2M", "512"
    public static func format(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }
}

/// A live Claude Code session as shown in the UI.
/// Where a session runs, which decides how "focus" and "quick reply" work.
public enum SessionHost: String, Codable, Equatable, Hashable, Sendable {
    /// `claude` in a terminal (entrypoint "cli"): focus / reply go through the editor extension.
    case terminal
    /// The Code tab of the Claude Desktop app (entrypoint "claude-desktop"): focus activates
    /// Claude Desktop; there is no way to type into it, so quick reply is not offered.
    case claudeDesktop

    /// Entrypoint Claude Code writes for sessions started from Claude Desktop (verified).
    public static let desktopEntrypoint = "claude-desktop"

    /// Classify from the session file's entrypoint; when it is missing or unknown, fall back to the
    /// executable paths of the claude process's ancestors (parent first): anything inside
    /// /Applications/Claude.app (the app or its `disclaimer` helper) means Claude Desktop.
    /// Note the claude binary itself lives in ~/Library/Application Support/Claude/claude-code/…/
    /// claude.app, which is deliberately not matched (ancestors only, exact app path).
    public static func classify(entrypoint: String?, ancestorPaths: [String],
                                desktopAppPath: String = NotchConstants.claudeDesktopAppPath) -> SessionHost {
        switch entrypoint?.lowercased() {
        case desktopEntrypoint: return .claudeDesktop
        case "cli": return .terminal
        default: break
        }
        let prefix = desktopAppPath.hasSuffix("/") ? desktopAppPath : desktopAppPath + "/"
        return ancestorPaths.contains { $0.hasPrefix(prefix) } ? .claudeDesktop : .terminal
    }

    /// Short label for tooltips / --dump.
    public var label: String { self == .claudeDesktop ? "Claude Desktop" : "terminal" }
}

public struct ClaudeSession: Identifiable, Equatable, Sendable {
    public var id: String { sessionId }
    public var pid: Int32
    /// Parent shell pid (== VS Code Terminal.processId). nil if unknown. For Claude Desktop
    /// sessions this is its `disclaimer` helper, not a terminal (see `host`).
    public var shellPid: Int32?
    /// Terminal (editor extension) or Claude Desktop.
    public var host: SessionHost
    public var sessionId: String
    public var cwd: String
    public var name: String
    public var status: SessionStatus
    public var startedAt: Date
    public var updatedAt: Date
    public var statusUpdatedAt: Date?
    public var version: String?
    public var tokens: TokenTotals
    public var model: String?
    public var lastAssistantText: String?
    /// Latest assistant message / real user prompt in the transcript (TranscriptReader).
    public var lastAssistantAt: Date?
    public var lastPromptAt: Date?
    public var transcriptPath: String?
    /// Session description (custom /rename title or Claude's auto title), from the transcript.
    public var title: String?
    /// Claude Desktop's record of this session (sidebar title, parent, focus); Desktop sessions only.
    public var desktop: DesktopSessionInfo?
    /// What to show as the row's headline: Claude Desktop's sidebar title, else the description
    /// if known, else the session name.
    public var displayTitle: String { desktop?.title ?? title ?? name }

    /// Last interaction: the newest of the last assistant message, the last prompt and the
    /// session file's status / update times (shown on the row as "3m").
    public var lastInteractionAt: Date {
        Self.lastInteraction(assistantAt: lastAssistantAt, promptAt: lastPromptAt,
                             statusUpdatedAt: statusUpdatedAt, updatedAt: updatedAt)
    }

    public static func lastInteraction(assistantAt: Date?, promptAt: Date?, statusUpdatedAt: Date?, updatedAt: Date) -> Date {
        [assistantAt, promptAt, statusUpdatedAt].compactMap { $0 }.reduce(updatedAt) { max($0, $1) }
    }

    public init(pid: Int32, shellPid: Int32? = nil, host: SessionHost = .terminal, sessionId: String, cwd: String, name: String,
                status: SessionStatus, startedAt: Date, updatedAt: Date, statusUpdatedAt: Date? = nil,
                version: String? = nil, tokens: TokenTotals = .zero, model: String? = nil,
                lastAssistantText: String? = nil, transcriptPath: String? = nil) {
        self.pid = pid; self.shellPid = shellPid; self.host = host; self.sessionId = sessionId; self.cwd = cwd
        self.name = name; self.status = status; self.startedAt = startedAt; self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt; self.version = version; self.tokens = tokens
        self.model = model; self.lastAssistantText = lastAssistantText; self.transcriptPath = transcriptPath
    }

    /// Build from a session file (tokens/model/text left empty; filled by TranscriptReader).
    public init(file: SessionFile, shellPid: Int32?, host: SessionHost? = nil) {
        func date(_ ms: Double?) -> Date? { ms.map { Date(timeIntervalSince1970: $0 / 1000) } }
        let cwd = file.cwd ?? ""
        self.init(pid: file.pid, shellPid: shellPid,
                  host: host ?? SessionHost.classify(entrypoint: file.entrypoint, ancestorPaths: []),
                  sessionId: file.sessionId, cwd: cwd,
                  name: file.name ?? (cwd as NSString).lastPathComponent,
                  status: SessionStatus(rawValue: file.status ?? "") ?? .unknown,
                  startedAt: date(file.startedAt) ?? Date(),
                  // No updatedAt in the file: never "now" (the row's time column would always say
                  // "now" and every poll would rebuild a changed session).
                  updatedAt: date(file.updatedAt) ?? date(file.statusUpdatedAt) ?? date(file.startedAt) ?? Date(),
                  statusUpdatedAt: date(file.statusUpdatedAt),
                  version: file.version)
    }

    public var isClaudeDesktop: Bool { host == .claudeDesktop }

    /// Last path component of cwd, e.g. "acme-api".
    public var projectName: String { (cwd as NSString).lastPathComponent }
    /// Short model name, e.g. "claude-opus-4-5-20251101" -> "opus-4-5".
    public var shortModel: String? {
        guard var m = model else { return nil }
        if m.hasPrefix("claude-") { m.removeFirst("claude-".count) }
        if let r = m.range(of: #"-\d{8}$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m
    }
}

// MARK: - Account usage

public struct UsageWindow: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String { label }
    /// e.g. "session", "week (all models)", "week (Fable)"
    public var label: String
    /// 0...100 (may exceed 100)
    public var percent: Int
    /// e.g. "Nov 19 at 12:30am (America/Los_Angeles)"
    public var resetsText: String

    public init(label: String, percent: Int, resetsText: String) {
        self.label = label; self.percent = percent; self.resetsText = resetsText
    }

    public var isNearLimit: Bool { percent >= NotchConstants.nearLimitPercent }
}

public struct UsageSnapshot: Equatable, Codable, Sendable {
    public var windows: [UsageWindow]
    /// nil = never fetched successfully.
    public var fetchedAt: Date?
    /// true when the latest fetch failed and `windows` are from an older fetch.
    public var stale: Bool

    public init(windows: [UsageWindow] = [], fetchedAt: Date? = nil, stale: Bool = false) {
        self.windows = windows; self.fetchedAt = fetchedAt; self.stale = stale
    }

    public static let empty = UsageSnapshot()

    /// The "Current session" window, if present.
    public var sessionWindow: UsageWindow? { windows.first { $0.label.lowercased() == "session" } }
    public var maxPercent: Int { windows.map(\.percent).max() ?? 0 }
    /// Highest window at/above the near-limit threshold.
    public var nearLimitWindow: UsageWindow? {
        windows.filter(\.isNearLimit).max { $0.percent < $1.percent }
    }
}

// MARK: - Permissions / hook wire format

/// Request sent by turnipot-hook over app.sock (one JSON line).
public struct HookRequest: Codable, Equatable, Sendable {
    public var type: String            // "permission" | "question" (AskUserQuestion) | "plan" (ExitPlanMode)
    public var sessionId: String
    public var cwd: String?
    public var toolName: String
    public var toolInput: JSONValue
    public var hookInput: JSONValue    // raw stdin JSON from Claude Code

    public init(type: String = "permission", sessionId: String, cwd: String?, toolName: String,
                toolInput: JSONValue, hookInput: JSONValue) {
        self.type = type; self.sessionId = sessionId; self.cwd = cwd; self.toolName = toolName
        self.toolInput = toolInput; self.hookInput = hookInput
    }
}

/// Response sent by the app back to turnipot-hook (one JSON line). nil fields are omitted.
public struct HookResponse: Codable, Equatable, Sendable {
    public var decision: String        // "allow" | "deny" | "ask"
    public var alwaysRule: String?     // e.g. "Bash(npm test:*)" — only with "allow"
    /// Replacement tool input ("allow" only): AskUserQuestion answers / the approved plan.
    public var updatedInput: JSONValue?
    /// Permission mode to switch to ("allow" only; plan approval): "default" | "acceptEdits" | "auto".
    public var mode: String?
    /// Deny reason shown to Claude ("deny" only; plan feedback).
    public var message: String?

    public init(decision: String, alwaysRule: String? = nil, updatedInput: JSONValue? = nil,
                mode: String? = nil, message: String? = nil) {
        self.decision = decision; self.alwaysRule = alwaysRule; self.updatedInput = updatedInput
        self.mode = mode; self.message = message
    }
}

public enum PermissionDecision: Equatable, Sendable {
    case allow
    /// Allow and add a permanent allow rule (rule string as in settings.json permissions.allow).
    case allowAlways(rule: String)
    case deny
    /// Let Claude Code show its normal terminal prompt ("Open session" button / timeout / app quit).
    case ask
    /// AskUserQuestion answered: allow with `updatedInput` = original input + `answers`.
    case answer(updatedInput: JSONValue)
    /// ExitPlanMode approved: allow with the input echoed, then switch to `mode`.
    case approvePlan(updatedInput: JSONValue, mode: PlanApprovalMode)
    /// Deny with a message for Claude (ExitPlanMode "Keep planning…").
    case denyWithMessage(String)

    public var hookResponse: HookResponse {
        switch self {
        case .allow: return HookResponse(decision: "allow")
        case .allowAlways(let rule): return HookResponse(decision: "allow", alwaysRule: rule)
        case .deny: return HookResponse(decision: "deny")
        case .ask: return HookResponse(decision: "ask")
        case .answer(let input): return HookResponse(decision: "allow", updatedInput: input)
        case .approvePlan(let input, let mode): return HookResponse(decision: "allow", updatedInput: input, mode: mode.rawValue)
        case .denyWithMessage(let m): return HookResponse(decision: "deny", message: m)
        }
    }
}

public struct PermissionRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var sessionId: String
    public var sessionName: String?
    public var cwd: String?
    public var toolName: String
    /// Human-readable one-liner, e.g. "npm test" for Bash, a file path for Edit/Write.
    public var summary: String
    public var toolInput: JSONValue
    /// Raw hook stdin JSON.
    public var raw: JSONValue
    public var receivedAt: Date

    /// permission / question (AskUserQuestion) / plan (ExitPlanMode), from the tool name.
    public var kind: RequestKind { RequestKind(toolName: toolName) }
    /// AskUserQuestion's questions (nil for other tools or unusable input).
    public var questions: [AskQuestion]? { kind == .question ? AskQuestion.parse(toolInput) : nil }
    /// ExitPlanMode's plan (nil for other tools or without plan text).
    public var plan: PlanContent? { kind == .plan ? PlanContent.parse(toolInput) : nil }

    public init(id: UUID = UUID(), sessionId: String, sessionName: String? = nil, cwd: String? = nil,
                toolName: String, summary: String, toolInput: JSONValue, raw: JSONValue,
                receivedAt: Date = Date()) {
        self.id = id; self.sessionId = sessionId; self.sessionName = sessionName; self.cwd = cwd
        self.toolName = toolName; self.summary = summary; self.toolInput = toolInput; self.raw = raw
        self.receivedAt = receivedAt
    }

    public init(hook: HookRequest, sessionName: String?) {
        self.init(sessionId: hook.sessionId, sessionName: sessionName, cwd: hook.cwd,
                  toolName: hook.toolName,
                  summary: PermissionRequest.summarize(toolName: hook.toolName, toolInput: hook.toolInput),
                  toolInput: hook.toolInput, raw: hook.hookInput)
    }

    /// Best-effort one-line summary of a tool call.
    public static func summarize(toolName: String, toolInput: JSONValue) -> String {
        let keys = ["command", "file_path", "path", "url", "pattern", "query", "notebook_path", "description", "prompt"]
        for k in keys {
            if let s = toolInput[k]?.stringValue, !s.isEmpty {
                return s.replacingOccurrences(of: "\n", with: " ⏎ ")
            }
        }
        return toolInput.compactString
    }

    /// Suggested rule for "Always allow", e.g. "Bash(npm test:*)" or "WebSearch"; nil when there is
    /// no safe rule (the button is hidden then).
    /// Prefers Claude Code's own `permission_suggestions` (an `addRules`/`allow` entry from the hook
    /// input), i.e. the same rule the terminal's "don't ask again" option would add. Without one it
    /// never guesses a broad rule: Bash gets the exact command (no prefix — "rm -rf x" must not
    /// become "rm -rf:*", "bash -c …" must not become "bash -c:*"), and tools whose rules need a
    /// path / domain specifier (Edit, Write, Read, WebFetch, …) get nothing, since a bare tool
    /// name would allow every file / URL forever.
    public var suggestedAlwaysRule: String? {
        if case .array(let suggestions)? = raw["permission_suggestions"] {
            for s in suggestions {
                guard s["type"]?.stringValue == "addRules", s["behavior"]?.stringValue == "allow",
                      case .array(let rules)? = s["rules"], let rule = rules.first,
                      let tool = rule["toolName"]?.stringValue, !tool.isEmpty else { continue }
                if let content = rule["ruleContent"]?.stringValue, !content.isEmpty {
                    return "\(tool)(\(content))"
                }
                return tool
            }
        }
        if toolName == "Bash" {
            let trimmed = (toolInput["command"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // "*" is a wildcard in permission rules: such a command has no exact-match rule.
            guard !trimmed.isEmpty, !trimmed.contains("*") else { return nil }
            return "Bash(\(trimmed))"
        }
        if Self.specifierTools.contains(toolName) { return nil }
        return toolName.isEmpty ? nil : toolName
    }

    /// Tools whose allow rules are scoped by a specifier (command, path, domain): a bare tool-name
    /// rule would allow all of it.
    static let specifierTools: Set<String> = ["Bash", "Edit", "MultiEdit", "Write", "NotebookEdit", "Read",
                                              "Glob", "Grep", "WebFetch", "PowerShell"]
}

// MARK: - VSCodium bridge wire format

/// Request to the VSCodium extension socket (one JSON line). Response: {"ok":Bool}.
public struct BridgeRequest: Codable, Equatable, Sendable {
    public var type: String       // "focus" | "send"
    public var shellPid: Int32
    public var text: String?

    public static func focus(shellPid: Int32) -> BridgeRequest { BridgeRequest(type: "focus", shellPid: shellPid, text: nil) }
    public static func send(shellPid: Int32, text: String) -> BridgeRequest { BridgeRequest(type: "send", shellPid: shellPid, text: text) }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    /// focus: the editor app hosting the terminal (VSCodium / VS Code / Cursor) — the app activates it.
    public var appPath: String?
    public init(ok: Bool, appPath: String? = nil) { self.ok = ok; self.appPath = appPath }
}

// MARK: - UI state

public enum IslandMode: Equatable, Sendable {
    case collapsed
    case finished(sessionId: String)
    case permission(requestId: UUID)
    case expanded
    case nearLimit
    /// A usage window just reset (AppState.usageReset): the turnip gets watered.
    case usageReset
    /// "While you were away" summary (AppState.awaySummary).
    case awaySummary
    /// Scrollable reply reader for one session (AppState.readerSessionId). Behaves as pinned.
    case reader(sessionId: String)
}

public enum MascotMood: String, Equatable, Sendable, CaseIterable {
    case sleeping   // idle
    case bouncing   // working
    case shake      // needs input
    case hop        // finished
    case sweat      // usage >= 85%
}

/// Short-lived events (drive drop-downs / mascot hops).
public struct TransientEvent: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sessionFinished(sessionId: String)
        case sessionStarted(sessionId: String)
        case sessionEnded(sessionId: String)
        case usageNearLimit(label: String, percent: Int)
    }
    public let id: UUID
    public var kind: Kind
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: UUID = UUID(), kind: Kind, createdAt: Date = Date(), lifetime: TimeInterval) {
        self.id = id; self.kind = kind; self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(lifetime)
    }
}

// MARK: - Subagents (Agent-tool subagents and workflow agents of a session)

public enum SubagentStatus: String, Codable, Equatable, Sendable {
    /// Transcript written to within `SubagentRules.runningWindow`.
    case running
    /// meta.json says "finished": true (Agent tool) or the workflow journal has its result.
    case done
    /// Not finished and silent for a while (killed / abandoned).
    case stalled
}

public enum SubagentRules {
    /// An unfinished agent whose transcript changed within this window counts as running.
    public static let runningWindow: TimeInterval = 5 * 60
    /// Done / stalled agents stay visible for this long after their last write.
    public static let recentWindow: TimeInterval = 10 * 60
    /// Max agent / workflow rows per session in the expanded panel (then "+N more").
    public static let maxRowsPerSession = 4

    /// finished -> done; else running if written recently; else stalled.
    public static func classify(finished: Bool, lastWrite: Date, now: Date) -> SubagentStatus {
        if finished { return .done }
        return now.timeIntervalSince(lastWrite) < runningWindow ? .running : .stalled
    }

    /// Running ones always; done / stalled ones only for `recentWindow` after their last write.
    public static func isVisible(status: SubagentStatus, lastWrite: Date, now: Date) -> Bool {
        status == .running || now.timeIntervalSince(lastWrite) < recentWindow
    }
}

/// One subagent transcript (subagents/agent-<id>.jsonl + .meta.json).
public struct SubagentInfo: Identifiable, Equatable, Sendable {
    public var id: String { agentId }
    public var agentId: String
    public var agentType: String
    /// Agent-tool description, or the workflow agent's label.
    public var description: String
    public var model: String?
    public var isFork: Bool
    /// Set for workflow agents.
    public var workflowRunId: String?
    public var workflowPhase: String?
    public var status: SubagentStatus
    /// Creation of the agent transcript.
    public var startedAt: Date
    /// Last modification of the agent transcript.
    public var lastWrite: Date
    /// "Bash: swift build", "Edit ExpandedView.swift", ... (latest tool use).
    public var lastAction: String?
    /// Short snippet of the latest assistant text.
    public var lastText: String?
    /// Tool uses so far (counted incrementally), nil if unknown.
    public var toolUses: Int?

    public init(agentId: String, agentType: String = "general-purpose", description: String, model: String? = nil,
                isFork: Bool = false, workflowRunId: String? = nil, workflowPhase: String? = nil,
                status: SubagentStatus, startedAt: Date, lastWrite: Date, lastAction: String? = nil,
                lastText: String? = nil, toolUses: Int? = nil) {
        self.agentId = agentId; self.agentType = agentType; self.description = description; self.model = model
        self.isFork = isFork; self.workflowRunId = workflowRunId; self.workflowPhase = workflowPhase
        self.status = status; self.startedAt = startedAt; self.lastWrite = lastWrite
        self.lastAction = lastAction; self.lastText = lastText; self.toolUses = toolUses
    }

    /// Running: time since start; done / stalled: start -> last write.
    public func elapsed(now: Date) -> TimeInterval {
        max(0, (status == .running ? now : lastWrite).timeIntervalSince(startedAt))
    }

    public func isVisible(now: Date) -> Bool {
        SubagentRules.isVisible(status: status, lastWrite: lastWrite, now: now)
    }
}

/// One workflow run (subagents/workflows/wf_<runId>/).
public struct WorkflowInfo: Identifiable, Equatable, Sendable {
    public var id: String { runId }
    public var runId: String
    /// From workflows/scripts/<name>-<runId>.js; falls back to the run id.
    public var name: String
    /// Phase of the latest running agent, else of the latest started agent.
    public var phase: String?
    public var doneCount: Int
    public var totalCount: Int
    public var status: SubagentStatus
    public var startedAt: Date
    public var lastWrite: Date
    public var agents: [SubagentInfo]

    public init(runId: String, name: String, phase: String?, doneCount: Int, totalCount: Int,
                status: SubagentStatus, startedAt: Date, lastWrite: Date, agents: [SubagentInfo]) {
        self.runId = runId; self.name = name; self.phase = phase; self.doneCount = doneCount
        self.totalCount = totalCount; self.status = status; self.startedAt = startedAt
        self.lastWrite = lastWrite; self.agents = agents
    }

    public func elapsed(now: Date) -> TimeInterval {
        max(0, (status == .running ? now : lastWrite).timeIntervalSince(startedAt))
    }

    public func isVisible(now: Date) -> Bool {
        SubagentRules.isVisible(status: status, lastWrite: lastWrite, now: now)
    }
}

/// Everything found under ~/.claude/projects/<encoded-cwd>/<sessionId>/subagents.
public struct SessionSubagents: Equatable, Sendable {
    /// Agent-tool subagents (not part of a workflow), newest first.
    public var agents: [SubagentInfo]
    /// Workflow runs, newest first.
    public var workflows: [WorkflowInfo]

    public init(agents: [SubagentInfo] = [], workflows: [WorkflowInfo] = []) {
        self.agents = agents; self.workflows = workflows
    }

    public static let empty = SessionSubagents()
    public var isEmpty: Bool { agents.isEmpty && workflows.isEmpty }

    /// Running agents, standalone and inside workflows.
    public var runningCount: Int {
        agents.filter { $0.status == .running }.count
            + workflows.reduce(0) { $0 + $1.agents.filter { $0.status == .running }.count }
    }

    /// Only what the UI shows at `now`: visible standalone agents and visible workflows.
    public func visible(now: Date) -> SessionSubagents {
        SessionSubagents(agents: agents.filter { $0.isVisible(now: now) },
                         workflows: workflows.filter { $0.isVisible(now: now) })
    }

    /// One line of the per-session list in the expanded panel.
    public enum Row: Identifiable, Equatable, Sendable {
        case agent(SubagentInfo, nested: Bool)
        case workflow(WorkflowInfo)
        case more(Int)

        public var id: String {
            switch self {
            case .agent(let a, _): return "a-" + a.agentId
            case .workflow(let w): return "w-" + w.runId
            case .more: return "more"
            }
        }
    }

    /// Rows to show: visible workflows (header + their running agents) first, then running
    /// standalone agents, then recently finished / stalled ones. At most `maxRows` rows, plus a
    /// "+N more" row counting the items that didn't fit.
    public func rows(now: Date, maxRows: Int = SubagentRules.maxRowsPerSession) -> [Row] {
        var items: [Row] = []
        for w in workflows where w.isVisible(now: now) {
            items.append(.workflow(w))
            for a in w.agents where a.status == .running { items.append(.agent(a, nested: true)) }
        }
        let visible = agents.filter { $0.isVisible(now: now) }
        let running = visible.filter { $0.status == .running }.sorted { $0.startedAt > $1.startedAt }
        let others = visible.filter { $0.status != .running }.sorted { $0.lastWrite > $1.lastWrite }
        items += (running + others).map { .agent($0, nested: false) }
        guard items.count > maxRows else { return items }
        return Array(items.prefix(maxRows)) + [.more(items.count - maxRows)]
    }
}
