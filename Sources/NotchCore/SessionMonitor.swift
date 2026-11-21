import Foundation
import Darwin

/// Watches ~/.claude/sessions (DispatchSource on the directory + fallback poll every
/// NotchConstants.sessionPollInterval) and pushes live sessions into AppState.
/// Also triggers TranscriptReader for each live session (busy sessions every tick,
/// idle ones when their file changed) and pushes results via AppState.updateTranscript.
///
/// Busy -> idle "finished" events are produced by AppState.updateSessions (it diffs the
/// previous and incoming status), so this monitor only has to deliver fresh statuses.
@MainActor
public final class SessionMonitor {
    public let appState: AppState
    public let sessionsDir: URL
    public let transcriptReader: TranscriptReader
    public let subagentScanner: SubagentScanner

    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var transcriptTask: Task<Void, Never>?
    private var transcriptPending = false
    private var subagentTask: Task<Void, Never>?
    /// pid -> parent pid (a claude process never changes its parent shell while alive).
    private var parentCache: [Int32: Int32] = [:]
    /// pid -> host (fixed for the life of the process).
    private var hostCache: [Int32: SessionHost] = [:]

    public init(appState: AppState,
                sessionsDir: URL = NotchPaths.sessionsDir,
                transcriptReader: TranscriptReader = TranscriptReader(),
                subagentScanner: SubagentScanner = SubagentScanner()) {
        self.appState = appState
        self.sessionsDir = sessionsDir
        self.transcriptReader = transcriptReader
        self.subagentScanner = subagentScanner
    }

    /// Start watching + polling; performs an immediate refresh.
    public func start() {
        stop()
        openDirectoryWatcher()
        let t = Timer(timeInterval: NotchConstants.sessionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.dirSource == nil { self.openDirectoryWatcher() }
                self.refresh()
            }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        dirSource?.cancel(); dirSource = nil
        debounce?.cancel(); debounce = nil
        transcriptTask?.cancel(); transcriptTask = nil
        subagentTask?.cancel(); subagentTask = nil
        transcriptPending = false
    }

    private func openDirectoryWatcher() {
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }   // dir may not exist yet; the timer retries
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .rename, .delete, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mask = self.dirSource?.data ?? []
                if mask.contains(.delete) || mask.contains(.rename) {
                    // Directory itself went away/moved: reopen on next tick.
                    self.dirSource?.cancel(); self.dirSource = nil
                }
                self.scheduleDebouncedRefresh()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    /// Coalesce bursts of directory events (Claude rewrites the file via temp+rename).
    private func scheduleDebouncedRefresh() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    /// Re-scan the directory now, update AppState, then refresh transcripts (off-main via actor).
    public func refresh() {
        let sessions = Self.liveSessions(in: sessionsDir, parentCache: &parentCache, hostCache: &hostCache)
        appState.updateSessions(sessions)
        refreshTranscripts(for: sessions)
        refreshSubagents()
    }

    /// Scan subagent dirs of live sessions (off-main via actor; unchanged files come from cache).
    /// Runs on every refresh, but never overlaps itself: a tick that finds a scan running skips.
    private func refreshSubagents() {
        guard subagentTask == nil else { return }
        let targets = appState.sessions.map { ($0.sessionId, $0.cwd, $0.transcriptPath) }
        let scanner = subagentScanner
        subagentTask = Task { [weak self] in
            await scanner.retain(sessionIds: Set(targets.map(\.0)))
            var results: [String: SessionSubagents] = [:]
            let now = Date()
            for (id, cwd, path) in targets {
                if Task.isCancelled { break }
                results[id] = await scanner.scan(sessionId: id, cwd: cwd, transcriptPath: path, now: now)
            }
            guard let self, !Task.isCancelled else { return }
            self.appState.updateSubagents(results)
            self.subagentTask = nil
        }
    }

    private func refreshTranscripts(for sessions: [ClaudeSession]) {
        guard transcriptTask == nil else { transcriptPending = true; return }
        let targets = sessions.map { ($0.sessionId, $0.cwd) }
        let ids = Set(targets.map(\.0))
        let reader = transcriptReader
        transcriptTask = Task { [weak self] in
            await reader.retain(sessionIds: ids)
            var results: [(String, TranscriptSummary)] = []
            for (id, cwd) in targets {
                if Task.isCancelled { break }
                if let summary = await reader.read(sessionId: id, cwd: cwd) {
                    results.append((id, summary))
                }
            }
            guard let self, !Task.isCancelled else { return }
            for (id, summary) in results {
                self.appState.updateTranscript(sessionId: id, summary: summary)
            }
            self.transcriptTask = nil
            if self.transcriptPending {
                self.transcriptPending = false
                self.refreshTranscripts(for: self.appState.sessions)
            }
        }
    }

    // MARK: Helpers (nonisolated, unit-testable)

    /// Load files, drop dead pids / headless helper runs, resolve parent shell pids.
    nonisolated static func liveSessions(in dir: URL, parentCache: inout [Int32: Int32],
                                         hostCache: inout [Int32: SessionHost]) -> [ClaudeSession] {
        let files = loadSessionFiles(in: dir).filter {
            isAlive(pid: $0.pid) && !isPidReused($0) && isUserFacing($0)
        }
        let livePids = Set(files.map(\.pid))
        parentCache = parentCache.filter { livePids.contains($0.key) }
        hostCache = hostCache.filter { livePids.contains($0.key) }
        let me = getpid()
        var result: [ClaudeSession] = []
        var seen = Set<String>()
        for f in files.sorted(by: { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }) {
            guard !seen.contains(f.sessionId) else { continue }   // keep newest file per session id
            let ppid: Int32?
            if let cached = parentCache[f.pid] { ppid = cached } else {
                ppid = parentPid(of: f.pid)
                if let ppid { parentCache[f.pid] = ppid }
            }
            if ppid == me { continue }   // spawned by us (e.g. `claude -p "/usage"`)
            seen.insert(f.sessionId)
            let host: SessionHost
            if let cached = hostCache[f.pid] { host = cached } else {
                host = Self.host(of: f, parentPid: ppid)
                hostCache[f.pid] = host
            }
            result.append(ClaudeSession(file: f, shellPid: ppid, host: host))
        }
        return result.sorted { $0.startedAt < $1.startedAt }
    }

    /// Terminal vs Claude Desktop: the entrypoint decides; only when it is missing/unknown is the
    /// process tree walked (parent chain executable paths).
    public nonisolated static func host(of f: SessionFile, parentPid: Int32? = nil) -> SessionHost {
        switch f.entrypoint?.lowercased() {
        case SessionHost.desktopEntrypoint: return .claudeDesktop
        case "cli": return .terminal
        default:
            return SessionHost.classify(entrypoint: f.entrypoint,
                                        ancestorPaths: ancestorPaths(of: f.pid, firstParent: parentPid))
        }
    }

    /// Executable paths of `pid`'s ancestors, parent first (stops at launchd or after `maxDepth`).
    public nonisolated static func ancestorPaths(of pid: Int32, firstParent: Int32? = nil, maxDepth: Int = 8) -> [String] {
        var out: [String] = []
        var cur = firstParent ?? parentPid(of: pid)
        while let p = cur, p > 1, out.count < maxDepth {
            if let path = processPath(of: p) { out.append(path) }
            cur = parentPid(of: p)
        }
        return out
    }

    /// Executable path via proc_pidpath. nil on failure.
    public nonisolated static func processPath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// Headless `claude -p` runs register with entrypoint "sdk-cli" (verified); SDK hosts use
    /// other "sdk-*" values. Those are not interactive sessions the user can focus.
    nonisolated static func isUserFacing(_ f: SessionFile) -> Bool {
        if let e = f.entrypoint?.lowercased(), e.hasPrefix("sdk") { return false }
        return true
    }

    /// Decode every <pid>.json in `dir` (ignore *.key and undecodable files).
    public nonisolated static func loadSessionFiles(in dir: URL) -> [SessionFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let decoder = JSONDecoder()
        var out: [SessionFile] = []
        for name in names where name.hasSuffix(".json") {
            let base = String(name.dropLast(5))
            guard !base.isEmpty, base.allSatisfy(\.isNumber) else { continue }
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(SessionFile.self, from: data) else { continue }
            out.append(file)
        }
        return out
    }

    /// kill(pid, 0) == 0 || errno == EPERM
    public nonisolated static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// True when the pid in a (stale) session file now belongs to a different, newer process:
    /// a claude process always starts a moment *before* it writes `startedAt`, so a process that
    /// started well after `startedAt` cannot be that session.
    public nonisolated static func isPidReused(_ f: SessionFile) -> Bool {
        guard let startedMs = f.startedAt, startedMs > 0, let procStart = processStartTime(of: f.pid) else { return false }
        return procStart.timeIntervalSince1970 > startedMs / 1000 + 10
    }

    /// Process start time via sysctl(KERN_PROC_PID) -> kp_proc.p_starttime. nil on failure.
    public nonisolated static func processStartTime(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// Parent pid via sysctl(KERN_PROC_PID) -> kinfo_proc.kp_eproc.e_ppid. nil on failure.
    public nonisolated static func parentPid(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
