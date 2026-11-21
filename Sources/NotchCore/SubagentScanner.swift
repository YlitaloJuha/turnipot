import Foundation

/// Finds the subagents of a session: Agent-tool subagents and workflow agents, stored next to
/// the session transcript in ~/.claude/projects/<encoded-cwd>/<sessionId>/subagents/:
///
///     agent-<id>.jsonl + agent-<id>.meta.json            Agent-tool subagents
///     workflows/wf_<runId>/agent-<id>.{jsonl,meta.json}  workflow agents
///     workflows/wf_<runId>/journal.jsonl                 {"type":"started"|"result","agentId",...}
///
/// and the workflow name from <sessionId>/workflows/scripts/<name>-wf_<runId>.js.
///
/// Agent transcripts can be several MB, so only their last ~48KB is parsed (latest tool use and
/// text); tool uses are counted incrementally by a byte search over newly appended data. Results
/// are cached per file by size / mtime, so unchanged agents are never re-read; only the status
/// (which depends on the clock) is recomputed on every scan. Thread-safe (actor).
public actor SubagentScanner {

    public init(projectsDir: URL = NotchPaths.projectsDir) {
        self.projectsDir = projectsDir
    }

    private let projectsDir: URL

    /// Metadata in agent-<id>.meta.json (only the fields we use).
    public struct Meta: Decodable, Equatable, Sendable {
        public var agentType: String?
        public var description: String?
        public var model: String?
        public var isFork: Bool?
        public var parentAgentId: String?
        /// Present (true) once the agent is done; absent while it runs (verified).
        public var finished: Bool?
        public var workflowPhase: String?
        public var inWorkflowRun: Bool?
    }

    /// What the tail of an agent transcript says.
    public struct TailSummary: Equatable, Sendable {
        public var lastAction: String?
        public var lastText: String?
        public init(lastAction: String? = nil, lastText: String? = nil) {
            self.lastAction = lastAction; self.lastText = lastText
        }
    }

    /// Parsed workflow journal.
    public struct Journal: Equatable, Sendable {
        public struct Started: Equatable, Sendable { public var agentId, label: String; public var phase: String? }
        public var started: [Started] = []
        public var results: Set<String> = []
        public init() {}
    }

    private struct AgentEntry {
        var inode: UInt64 = 0
        var size: UInt64 = 0
        var mtime = Date.distantPast
        var created = Date.distantPast
        var metaMtime: Date?
        var meta: Meta?
        var tail = TailSummary()
        var countOffset: UInt64 = 0
        var toolUses = 0
        var carry = Data()
    }

    private struct JournalEntry { var size: UInt64; var mtime: Date; var journal: Journal }

    /// sessionId -> jsonl path -> entry
    private var agentCache: [String: [String: AgentEntry]] = [:]
    /// sessionId -> journal path -> entry
    private var journalCache: [String: [String: JournalEntry]] = [:]
    /// runId -> workflow name
    private var workflowNames: [String: String] = [:]

    static let tailBytes = 48 * 1024
    static let wideTailBytes = 512 * 1024
    private static let countChunk = 4 * 1024 * 1024
    private static let toolUsePattern = Data(#""type":"tool_use""#.utf8)

    // MARK: Scan

    /// ~/.claude/projects/<encoded-cwd>/<sessionId> (the transcript path minus ".jsonl" if known).
    public func sessionDir(sessionId: String, cwd: String, transcriptPath: String?) -> URL {
        if let p = transcriptPath, p.hasSuffix(".jsonl") {
            return URL(fileURLWithPath: String(p.dropLast(6)), isDirectory: true)
        }
        return projectsDir
            .appendingPathComponent(NotchPaths.encodeProjectDirName(cwd: cwd), isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    public func scan(sessionId: String, cwd: String, transcriptPath: String?, now: Date = Date()) -> SessionSubagents {
        let dir = sessionDir(sessionId: sessionId, cwd: cwd, transcriptPath: transcriptPath)
        let subDir = dir.appendingPathComponent("subagents", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: subDir.path) else {
            agentCache[sessionId] = nil; journalCache[sessionId] = nil
            return .empty
        }
        var seenAgents = Set<String>()
        var seenJournals = Set<String>()

        var agents = scanAgents(in: subDir, sessionId: sessionId, now: now, finishedIds: [], seen: &seenAgents)
        agents.sort { $0.startedAt > $1.startedAt }

        var workflows: [WorkflowInfo] = []
        let wfRoot = subDir.appendingPathComponent("workflows", isDirectory: true)
        if let runs = try? fm.contentsOfDirectory(atPath: wfRoot.path) {
            for runId in runs where runId.hasPrefix("wf_") {
                let runDir = wfRoot.appendingPathComponent(runId, isDirectory: true)
                if let w = scanWorkflow(runId: runId, runDir: runDir, sessionDir: dir, sessionId: sessionId,
                                        now: now, seenAgents: &seenAgents, seenJournals: &seenJournals) {
                    workflows.append(w)
                }
            }
        }
        workflows.sort { $0.startedAt > $1.startedAt }

        agentCache[sessionId] = agentCache[sessionId]?.filter { seenAgents.contains($0.key) }
        journalCache[sessionId] = journalCache[sessionId]?.filter { seenJournals.contains($0.key) }
        return SessionSubagents(agents: agents, workflows: workflows)
    }

    /// Drop caches of sessions that are gone.
    public func retain(sessionIds: Set<String>) {
        agentCache = agentCache.filter { sessionIds.contains($0.key) }
        journalCache = journalCache.filter { sessionIds.contains($0.key) }
    }

    private func scanAgents(in dir: URL, sessionId: String, now: Date, finishedIds: Set<String>,
                            workflow: (runId: String, labels: [String: Journal.Started])? = nil,
                            seen: inout Set<String>) -> [SubagentInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [SubagentInfo] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let agentId = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let jsonl = dir.appendingPathComponent(name)
            let metaURL = dir.appendingPathComponent("agent-\(agentId).meta.json")
            guard let entry = refreshAgent(jsonl: jsonl, metaURL: metaURL, sessionId: sessionId) else { continue }
            seen.insert(jsonl.path)
            let meta = entry.meta
            let started = workflow?.labels[agentId]
            let finished = meta?.finished == true || finishedIds.contains(agentId)
            out.append(SubagentInfo(
                agentId: agentId,
                agentType: meta?.agentType ?? (workflow != nil ? "workflow-subagent" : "general-purpose"),
                description: Self.clean(meta?.description) ?? started?.label ?? agentId,
                model: meta?.model,
                isFork: meta?.isFork ?? false,
                workflowRunId: workflow?.runId,
                workflowPhase: meta?.workflowPhase ?? started?.phase,
                status: SubagentRules.classify(finished: finished, lastWrite: entry.mtime, now: now),
                startedAt: min(entry.created, entry.mtime),
                lastWrite: entry.mtime,
                lastAction: entry.tail.lastAction,
                lastText: entry.tail.lastText,
                toolUses: entry.toolUses))
        }
        return out
    }

    private func scanWorkflow(runId: String, runDir: URL, sessionDir: URL, sessionId: String, now: Date,
                              seenAgents: inout Set<String>, seenJournals: inout Set<String>) -> WorkflowInfo? {
        let journalURL = runDir.appendingPathComponent("journal.jsonl")
        let jattrs = Self.attributes(journalURL)
        var journal = Journal()
        if let jattrs {
            seenJournals.insert(journalURL.path)
            if let cached = journalCache[sessionId]?[journalURL.path],
               cached.size == jattrs.size, cached.mtime == jattrs.mtime {
                journal = cached.journal
            } else if let data = try? Data(contentsOf: journalURL) {
                journal = Self.parseJournal(data)
                journalCache[sessionId, default: [:]][journalURL.path] =
                    JournalEntry(size: jattrs.size, mtime: jattrs.mtime, journal: journal)
            }
        }
        let labels = Dictionary(journal.started.map { ($0.agentId, $0) }, uniquingKeysWith: { _, b in b })
        var agents = scanAgents(in: runDir, sessionId: sessionId, now: now, finishedIds: journal.results,
                                workflow: (runId, labels), seen: &seenAgents)
        guard !agents.isEmpty || jattrs != nil else { return nil }
        // Journal order = launch order; agents without a journal entry go last, by start time.
        let order = Dictionary(journal.started.enumerated().map { ($1.agentId, $0) }, uniquingKeysWith: { a, _ in a })
        agents.sort { (order[$0.agentId] ?? Int.max, $0.startedAt) < (order[$1.agentId] ?? Int.max, $1.startedAt) }

        let startedAt = ([jattrs.map { min($0.created, $0.mtime) }].compactMap { $0 } + agents.map(\.startedAt)).min() ?? now
        let lastWrite = ([jattrs?.mtime].compactMap { $0 } + agents.map(\.lastWrite)).max() ?? startedAt
        // Count by label: a retried step gets a new agent id under the same label, and the step
        // is done once any of its attempts has a result.
        let total: Int, done: Int
        if journal.started.isEmpty {
            total = agents.count
            done = agents.filter { $0.status == .done }.count
        } else {
            total = Set(journal.started.map(\.label)).count
            done = Set(journal.started.filter { journal.results.contains($0.agentId) }.map(\.label)).count
        }
        let running = agents.filter { $0.status == .running }

        let status: SubagentStatus
        if !running.isEmpty {
            status = .running
        } else if total > 0 && done >= total {
            // Between phases the journal briefly has every result in; a fresh journal write means
            // the script is probably still going.
            status = now.timeIntervalSince(lastWrite) < 30 ? .running : .done
        } else {
            status = SubagentRules.classify(finished: false, lastWrite: lastWrite, now: now)
        }
        let phase = running.last?.workflowPhase ?? journal.started.last?.phase ?? agents.last?.workflowPhase
        return WorkflowInfo(runId: runId, name: workflowName(runId: runId, sessionDir: sessionDir),
                            phase: phase, doneCount: done, totalCount: total, status: status,
                            startedAt: startedAt, lastWrite: lastWrite, agents: agents)
    }

    /// <sessionDir>/workflows/scripts/<name>-<runId>.js -> name (cached once found).
    private func workflowName(runId: String, sessionDir: URL) -> String {
        if let n = workflowNames[runId] { return n }
        let scripts = sessionDir.appendingPathComponent("workflows/scripts", isDirectory: true)
        let suffix = "-\(runId).js"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: scripts.path),
           let file = names.first(where: { $0.hasSuffix(suffix) }) {
            let name = String(file.dropLast(suffix.count))
            if !name.isEmpty { workflowNames[runId] = name; return name }
        }
        return runId
    }

    /// Re-read meta / tail / tool count only for files that changed since the last scan.
    private func refreshAgent(jsonl: URL, metaURL: URL, sessionId: String) -> AgentEntry? {
        guard let attrs = Self.attributes(jsonl) else { return nil }
        var e = agentCache[sessionId]?[jsonl.path] ?? AgentEntry()

        let metaAttrs = Self.attributes(metaURL)
        if metaAttrs?.mtime != e.metaMtime {
            e.metaMtime = metaAttrs?.mtime
            e.meta = (try? Data(contentsOf: metaURL)).flatMap(Self.parseMeta)
        }

        if attrs.inode != e.inode || attrs.size < e.countOffset {
            e = AgentEntry(metaMtime: e.metaMtime, meta: e.meta)   // replaced or truncated
        }
        if attrs.size != e.size || attrs.mtime != e.mtime || attrs.inode != e.inode {
            e.inode = attrs.inode; e.size = attrs.size; e.mtime = attrs.mtime; e.created = attrs.created
            if let handle = try? FileHandle(forReadingFrom: jsonl) {
                defer { try? handle.close() }
                let tail = Self.readTail(handle: handle, size: attrs.size)
                // Long tool-only stretches push the last text out of the tail: keep the old one.
                e.tail = TailSummary(lastAction: tail.lastAction ?? e.tail.lastAction,
                                     lastText: tail.lastText ?? e.tail.lastText)
                countToolUses(handle: handle, size: attrs.size, entry: &e)
            }
        }
        agentCache[sessionId, default: [:]][jsonl.path] = e
        return e
    }

    private func countToolUses(handle: FileHandle, size: UInt64, entry e: inout AgentEntry) {
        guard size > e.countOffset else { return }
        do {
            try handle.seek(toOffset: e.countOffset)
            while e.countOffset < size {
                let want = Int(min(UInt64(Self.countChunk), size - e.countOffset))
                guard let data = try handle.read(upToCount: want), !data.isEmpty else { break }
                e.countOffset += UInt64(data.count)
                var buf = e.carry
                buf.append(data)
                e.toolUses += Self.occurrences(of: Self.toolUsePattern, in: buf)
                // Keep a pattern-length-minus-one tail so a match split across reads is found once.
                let keep = min(buf.count, Self.toolUsePattern.count - 1)
                e.carry = Data(buf.suffix(keep))
            }
        } catch {}
    }

    private static func readTail(handle: FileHandle, size: UInt64) -> TailSummary {
        var window = UInt64(tailBytes)
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(size - start)) else { return TailSummary() }
            let t = parseTail(data, isFileStart: start == 0)
            // A single huge line (big Write / tool result) can fill the window: widen once.
            if t.lastAction == nil && start > 0 && window < UInt64(wideTailBytes) {
                window = UInt64(wideTailBytes)
                continue
            }
            return t
        }
    }

    // MARK: Pure parsing (unit-testable)

    public static func parseMeta(_ data: Data) -> Meta? {
        try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// Latest tool use and latest assistant text in a chunk of JSONL from the end of a transcript.
    /// When `isFileStart` is false the first line is assumed to be cut off and is skipped.
    /// A trailing "SubagentHandback" tool use is skipped in favour of the real work before it.
    public static func parseTail(_ data: Data, isFileStart: Bool) -> TailSummary {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if !isFileStart, !lines.isEmpty { lines.removeFirst() }
        var result = TailSummary()
        var fallbackAction: String?
        let marker = Data(#""type":"assistant""#.utf8)
        for line in lines.reversed() {
            if result.lastAction != nil && result.lastText != nil { break }
            guard line.range(of: marker) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any] else { continue }
            let blocks: [[String: Any]]
            if let c = message["content"] as? [[String: Any]] { blocks = c }
            else if let s = message["content"] as? String { blocks = [["type": "text", "text": s]] }
            else { continue }
            for block in blocks.reversed() {
                switch block["type"] as? String {
                case "tool_use" where result.lastAction == nil:
                    let name = block["name"] as? String ?? "tool"
                    let action = describe(tool: name, input: block["input"] as? [String: Any] ?? [:])
                    if bookkeepingTools.contains(name) { if fallbackAction == nil { fallbackAction = action } }
                    else { result.lastAction = action }
                case "text" where result.lastText == nil:
                    if let t = clean(block["text"] as? String) { result.lastText = String(t.prefix(200)) }
                default: break
                }
            }
        }
        if result.lastAction == nil { result.lastAction = fallbackAction }
        return result
    }

    /// Final hand-off tools: shown only when there is no real tool use before them in the tail.
    static let bookkeepingTools: Set<String> = ["SubagentHandback", "StructuredOutput"]

    /// "Bash: swift build", "Edit ExpandedView.swift", "Grep: TODO", else the tool name.
    public static func describe(tool: String, input: [String: Any]) -> String {
        func short(_ s: String, _ n: Int = 40) -> String {
            let one = s.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        func base(_ v: Any?) -> String? {
            guard let p = v as? String, !p.isEmpty else { return nil }
            return (p as NSString).lastPathComponent
        }
        switch tool {
        case "Bash":
            if let d = clean(input["description"] as? String) { return "Bash: " + short(d, 50) }
            if var c = clean(input["command"] as? String) {
                // `cd "<project>" && real command`: the cd is noise in a 40-char preview.
                if let r = c.range(of: #"^cd\s+("[^"]*"|'[^']*'|\S+)\s*(&&|;)\s*"#, options: .regularExpression),
                   r.upperBound < c.endIndex {
                    c = String(c[r.upperBound...])
                }
                return "Bash: " + short(c)
            }
        case "Edit", "Write", "Read", "MultiEdit":
            if let b = base(input["file_path"]) { return "\(tool) \(b)" }
        case "NotebookEdit":
            if let b = base(input["notebook_path"]) { return "\(tool) \(b)" }
        case "Grep", "Glob":
            if let p = clean(input["pattern"] as? String) { return "\(tool): " + short(p) }
        case "WebFetch":
            if let u = (input["url"] as? String).flatMap(URL.init(string:))?.host { return "WebFetch: \(u)" }
        case "WebSearch":
            if let q = clean(input["query"] as? String) { return "WebSearch: " + short(q) }
        case "Agent", "Task":
            if let d = clean(input["description"] as? String) { return "Agent: " + short(d) }
        case "SubagentHandback", "StructuredOutput":
            return "Handing back"
        default:
            break
        }
        if tool.hasPrefix("mcp__"), let last = tool.split(separator: "_", omittingEmptySubsequences: true).last {
            return String(last)
        }
        return tool
    }

    public static func parseJournal(_ data: Data) -> Journal {
        var j = Journal()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = obj["type"] as? String, let id = obj["agentId"] as? String else { continue }
            switch type {
            case "started":
                j.started.removeAll { $0.agentId == id }
                j.started.append(.init(agentId: id, label: obj["label"] as? String ?? id, phase: obj["phase"] as? String))
            case "result":
                j.results.insert(id)
            default: break
            }
        }
        return j
    }

    static func occurrences(of pattern: Data, in data: Data) -> Int {
        var count = 0
        var from = data.startIndex
        while from < data.endIndex, let r = data.range(of: pattern, in: from..<data.endIndex) {
            count += 1
            from = r.upperBound
        }
        return count
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private struct FileAttrs { var size: UInt64; var mtime: Date; var created: Date; var inode: UInt64 }

    private static func attributes(_ url: URL) -> FileAttrs? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = a[.modificationDate] as? Date ?? .distantPast
        return FileAttrs(size: (a[.size] as? NSNumber)?.uint64Value ?? 0, mtime: mtime,
                         created: a[.creationDate] as? Date ?? mtime,
                         inode: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}
