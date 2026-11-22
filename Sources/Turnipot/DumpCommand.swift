import Foundation
import ServiceManagement
import NotchCore

/// `Turnipot --dump [--no-usage]`: print live sessions (+ transcript token totals) and account
/// usage as JSON, then exit. Uses only the static NotchCore APIs, so no window, timers or sockets.
enum DumpCommand {
    static func run(includeUsage: Bool) -> Never {
        Task.detached {
            let json = await collect(includeUsage: includeUsage)
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
                ?? Data("{}".utf8)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        }
        dispatchMain()
    }

    /// `Turnipot --dump-replies=<sessionId>`: the reply reader's turns for a session (live or
    /// not; the transcript is found under ~/.claude/projects), plus how it was read.
    static func runReplies(sessionId: String) -> Never {
        Task.detached {
            let iso = ISO8601DateFormatter()
            let file = SessionMonitor.loadSessionFiles(in: NotchPaths.sessionsDir).first { $0.sessionId == sessionId }
            let reader = ReplyReader()
            let t0 = Date()
            let r = await reader.replies(sessionId: sessionId, cwd: file?.cwd ?? "")
            let ms = Date().timeIntervalSince(t0) * 1000
            let r2 = await reader.replies(sessionId: sessionId, cwd: file?.cwd ?? "")
            var json: [String: Any] = ["sessionId": sessionId, "found": r != nil]
            if let r {
                json["transcriptPath"] = r.transcriptPath ?? NSNull()
                json["bytesScanned"] = r.bytesScanned
                json["fileSize"] = ((try? FileManager.default.attributesOfItem(atPath: r.transcriptPath ?? "")[.size]) as? NSNumber)?.intValue ?? 0
                json["firstReadMs"] = Int(ms)
                json["secondReadSource"] = r2?.source.rawValue ?? NSNull()
                json["turns"] = r.turns.map { t -> [String: Any] in
                    [
                        "id": t.id,
                        "prompt": t.prompt ?? NSNull(),
                        "promptAt": t.promptAt.map { iso.string(from: $0) } ?? NSNull(),
                        "repliedAt": t.repliedAt.map { iso.string(from: $0) } ?? NSNull(),
                        "chars": t.text.count,
                        "blocks": MarkdownBlocks.parse(t.text).count,
                        "head": String(t.text.prefix(160)),
                        "tail": String(t.text.suffix(120)),
                    ]
                }
            }
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        }
        dispatchMain()
    }

    static func subagentsJSON(_ subs: SessionSubagents, now: Date, iso: ISO8601DateFormatter) -> [String: Any] {
        func agent(_ a: SubagentInfo) -> [String: Any] {
            var d: [String: Any] = [
                "agentId": a.agentId, "agentType": a.agentType, "description": a.description,
                "status": a.status.rawValue, "visible": a.isVisible(now: now), "isFork": a.isFork,
                "startedAt": iso.string(from: a.startedAt), "lastWrite": iso.string(from: a.lastWrite),
                "elapsed": Fmt.duration(seconds: a.elapsed(now: now)),
            ]
            d["model"] = a.model ?? NSNull()
            d["workflowPhase"] = a.workflowPhase ?? NSNull()
            d["lastAction"] = a.lastAction ?? NSNull()
            d["lastText"] = a.lastText.map { String($0.prefix(120)) } ?? NSNull()
            d["toolUses"] = a.toolUses ?? NSNull()
            return d
        }
        return [
            "agents": subs.agents.map(agent),
            "workflows": subs.workflows.map { w -> [String: Any] in
                ["runId": w.runId, "name": w.name, "phase": w.phase ?? NSNull(), "done": w.doneCount,
                 "total": w.totalCount, "status": w.status.rawValue, "visible": w.isVisible(now: now),
                 "startedAt": iso.string(from: w.startedAt), "lastWrite": iso.string(from: w.lastWrite),
                 "elapsed": Fmt.duration(seconds: w.elapsed(now: now)), "agents": w.agents.map(agent)]
            },
            "runningCount": subs.runningCount,
            "uiRows": subs.rows(now: now).map(\.id),
        ]
    }

    static func collect(includeUsage: Bool) async -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let files = SessionMonitor.loadSessionFiles(in: NotchPaths.sessionsDir)
            .filter { SessionMonitor.isAlive(pid: $0.pid) }
        let reader = TranscriptReader()
        let scanner = SubagentScanner()
        let now = Date()
        var sessions: [[String: Any]] = []
        for f in files {
            let ppid = SessionMonitor.parentPid(of: f.pid)
            var s = ClaudeSession(file: f, shellPid: ppid, host: SessionMonitor.host(of: f, parentPid: ppid))
            if let t = await reader.read(sessionId: s.sessionId, cwd: s.cwd) {
                s.tokens = t.tokens
                s.model = t.model
                s.lastAssistantText = t.lastAssistantText
                s.title = t.title
                s.transcriptPath = t.transcriptPath
            }
            var d: [String: Any] = [
                "pid": Int(s.pid),
                "sessionId": s.sessionId,
                "name": s.name,
                "cwd": s.cwd,
                "status": s.status.rawValue,
                "startedAt": iso.string(from: s.startedAt),
                "updatedAt": iso.string(from: s.updatedAt),
                "tokens": [
                    "input": s.tokens.input, "cacheCreation": s.tokens.cacheCreation,
                    "cacheRead": s.tokens.cacheRead, "output": s.tokens.output,
                    "lastContext": s.tokens.lastContext, "total": s.tokens.total,
                    "display": Fmt.tokens(s.tokens),
                    "contextDisplay": Fmt.context(s.tokens.lastContext),
                ],
            ]
            d["shellPid"] = s.shellPid.map { Int($0) } ?? NSNull()
            // "terminal" or "claudeDesktop"; entrypoint as written by Claude Code.
            d["host"] = s.host.rawValue
            d["entrypoint"] = f.entrypoint ?? NSNull()
            // Where focus / quick reply go (see TerminalBridge): Terminal / iTerm2 by tty, else the
            // editor extension by shellPid, falling back to activating the app in the parent chain.
            let loc = s.host == .terminal ? NativeTerminal.locate(pid: s.pid) : nil
            d["terminalApp"] = loc?.appPath ?? NSNull()
            d["tty"] = loc?.tty ?? NSNull()
            if s.host == .claudeDesktop {
                d["focus"] = "open -b \(NotchConstants.claudeDesktopBundleId)"
            } else if let loc, let t = loc.terminal {
                d["focus"] = "\(t.displayName) AppleScript (tty)"
            } else {
                d["focus"] = loc.map { "editor extension (shellPid), else open -a \($0.appPath)" } ?? "editor extension (shellPid)"
            }
            d["quickReply"] = s.host == .terminal
            d["model"] = s.model ?? NSNull()
            d["version"] = s.version ?? NSNull()
            d["transcriptPath"] = s.transcriptPath ?? NSNull()
            d["title"] = s.title ?? NSNull()
            d["lastAssistantText"] = s.lastAssistantText.map { String($0.prefix(300)) } ?? NSNull()
            // What an unseen row / the away summary would show for it.
            d["lastSentence"] = AttentionText.lastSentence(s.lastAssistantText) ?? NSNull()
            d["unseenKind"] = AttentionText.classify(s.lastAssistantText).rawValue
            let subs = await scanner.scan(sessionId: s.sessionId, cwd: s.cwd, transcriptPath: s.transcriptPath, now: now)
            d["subagents"] = subagentsJSON(subs, now: now, iso: iso)
            sessions.append(d)
        }
        sessions.sort { ($0["startedAt"] as? String ?? "") < ($1["startedAt"] as? String ?? "") }

        var usage: [String: Any] = ["skipped": !includeUsage]
        if includeUsage {
            if let bin = UsageMonitor.locateClaudeBinary() {
                usage["binary"] = bin
                do {
                    let out = try await UsageMonitor.runUsageCommand(binary: bin)
                    let windows = UsageMonitor.parse(out)
                    usage["windows"] = windows.map {
                        ["label": $0.label, "percent": $0.percent, "resetsText": $0.resetsText,
                         "isNearLimit": $0.isNearLimit] as [String: Any]
                    }
                    usage["fetchedAt"] = iso.string(from: Date())
                    if windows.isEmpty { usage["error"] = "no usage windows parsed" }
                } catch {
                    usage["error"] = String(describing: error)
                }
            } else {
                usage["error"] = "claude binary not found"
            }
        }
        return ["sessions": sessions, "usage": usage, "sessionsDir": NotchPaths.sessionsDir.path, "app": appInfo()]
    }

    /// Install state (read-only): version, where the app runs from, login item, hook registration.
    static func appInfo() -> [String: Any] {
        var app: [String: Any] = ["version": AppInfo.version ?? NSNull(), "bundlePath": AppInfo.bundlePath,
                                  "inApplications": AppInfo.isInApplications, "translocated": AppInfo.isTranslocated]
        if AppInfo.isAppBundle {
            switch SMAppService.mainApp.status {
            case .enabled: app["loginItem"] = "enabled"
            case .requiresApproval: app["loginItem"] = "requiresApproval"
            case .notRegistered: app["loginItem"] = "notRegistered"
            case .notFound: app["loginItem"] = "notFound"
            @unknown default: app["loginItem"] = "unknown"
            }
        }
        let text = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json").map { String(decoding: $0, as: UTF8.self) }
        if let plan = try? HookSettings.plan(settingsText: text, hookPath: nil) {
            app["hookCommands"] = plan.existingCommands
            app["hookPointsHere"] = (try? HookSettings.plan(settingsText: text, hookPath: AppInfo.hookPath))?.changes == false
        }
        app["checkForUpdates"] = UserDefaults.standard.object(forKey: UpdateCheck.enabledKey) as? Bool ?? true
        return app
    }
}
