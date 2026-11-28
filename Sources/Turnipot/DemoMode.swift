import Foundation
import NotchCore

/// `Turnipot --demo=<state>`: run the UI with fake data and no monitors / sockets, for visual
/// checks. States: idle, empty (no sessions: one-sided pill), working, finished, finished-stack (two cards), permission, nearlimit, expanded, plus the "missed
/// sessions" states: unseen (pill "2 done"), unseen-working ("● 1" + "2 done"), unseen-mixed
/// ("1 waiting · 1 done"), expanded-unseen (2 unseen rows, one waiting, + an idle row with 3
/// running agents), away (the "While you were away" summary), reader / reader-working (the
/// reply reader with a long Markdown reply; -working adds a busy newest turn). A Claude Desktop
/// session ("Onboarding flow polish") is in `expanded`; expanded-desktop (its ↩ slot open:
/// "Reply in Claude ↗"), finished-desktop and reader-desktop show its no-quick-reply variants.
/// All demo data is made up (sessions api-refactor / landing-page / docs-cleanup /
/// mobile-onboarding under ~/code/acme-*); it is also what `--export-media` records.
/// question (AskUserQuestion with 2 questions, step 1), question-single (1 question), plan (an
/// ExitPlanMode plan longer than the drop-down); --render adds question-multi (step 2,
/// multi-select + "Other…") and plan-feedback ("Keep planning…" open). Usage resets:
/// usage-reset (5h window 97% -> 0%; reset-before = the pill just before), usage-reset-week
/// (weekly 88% -> 3%; reset-week-before), away-reset (the away summary with a reset row).
@MainActor
enum DemoMode {
    static var requestedState: String? {
        for a in CommandLine.arguments where a.hasPrefix("--demo") {
            let parts = a.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]).lowercased() : "working"
        }
        return nil
    }

    /// Sample subagents for the expanded panel: a running workflow + Agent-tool subagents.
    static func demoSubagents(now: Date) -> [String: SessionSubagents] {
        func agent(_ id: String, _ desc: String, _ status: SubagentStatus, started: Double, last: Double = 0.1,
                   action: String, phase: String? = nil, run: String? = nil) -> SubagentInfo {
            SubagentInfo(agentId: id, agentType: run == nil ? "general-purpose" : "workflow-subagent",
                         description: desc, model: "claude-opus-5-5", workflowRunId: run, workflowPhase: phase,
                         status: status, startedAt: now.addingTimeInterval(-started * 60),
                         lastWrite: now.addingTimeInterval(-last * 60), lastAction: action)
        }
        let run = "wf_demo"
        let wfAgents = [
            agent("w1", "scaffold", .done, started: 30, last: 22, action: "Handing back", phase: "Scaffold", run: run),
            agent("w2", "build:api", .running, started: 21, action: "Bash: npm run build", phase: "Build", run: run),
            agent("w3", "build:ui", .running, started: 21, action: "Edit Checkout.tsx", phase: "Build", run: run),
            agent("w4", "build:webhooks", .done, started: 21, last: 9, action: "Write webhooks.ts", phase: "Build", run: run),
        ]
        let wf = WorkflowInfo(runId: run, name: "ship-checkout", phase: "Build", doneCount: 2, totalCount: 4,
                              status: .running, startedAt: now.addingTimeInterval(-30 * 60), lastWrite: now,
                              agents: wfAgents)
        return [
            "demo-landing-page": SessionSubagents(agents: [
                agent("a1", "Hero copy variants", .running, started: 7.4, action: "Read Hero.tsx"),
                agent("a2", "Responsive layout pass", .done, started: 22, last: 6, action: "Bash: git push"),
            ], workflows: [wf]),
            "demo-api-refactor": SessionSubagents(agents: [
                agent("b1", "Verify dead code: invoices", .running, started: 3.2, action: "Grep: legacy_charge"),
                agent("b2", "Check callers, items 1-7", .stalled, started: 14, last: 6, action: "Bash: pytest -q tests/api"),
            ]),
        ]
    }

    /// Sample turns for the reader demos: the newest has a heading, a list, inline code and a
    /// fenced code block and is longer than the viewport.
    static func readerTurns(now: Date = Date(), working: Bool = false) -> [ReplyTurn] {
        let newest = """
        Refactored the payment API's auth middleware. All **42 tests** pass and the API is unchanged.

        ## What changed

        - Moved token parsing into `AuthToken.parse(_:)` so every route shares one code path.
        - Expired tokens now return `401` with a `WWW-Authenticate` header instead of a bare `403`.
        - Removed the *legacy* session cookie fallback (it was only used by the old admin UI).
          It had no callers left after the migration.
        1. Run the migration once.
        2. Restart the API workers.

        ```swift
        func authenticate(_ req: Request) throws -> User {
            let token = try AuthToken.parse(req.headers["Authorization"])
            guard !token.isExpired else { throw AuthError.expired }
            return try users.find(token.subject)
        }
        ```

        | Route | Before | After |
        |---|---|---|
        | /login | 403 | 401 |
        | /refresh | 500 | 401 |

        > Note: the admin UI still sends the cookie; it is ignored now.

        See [the RFC](https://www.rfc-editor.org/rfc/rfc6750) for the header format. Want me to also update the API docs?
        """
        var turns = [
            ReplyTurn(id: "t1", prompt: "why does /login return 403 for expired tokens?", promptAt: now.addingTimeInterval(-3600),
                      text: "Because the middleware treats every parse failure as *forbidden*. I'll fix it.", repliedAt: now.addingTimeInterval(-3500)),
            ReplyTurn(id: "t2", prompt: "ok go ahead and refactor it", promptAt: now.addingTimeInterval(-1500),
                      text: newest, repliedAt: now.addingTimeInterval(-700)),
        ]
        if working {
            turns.append(ReplyTurn(id: "t3", prompt: "yes, update the API docs too", promptAt: now.addingTimeInterval(-40),
                                   text: "Updating `docs/api.md` now — starting with the auth section.", repliedAt: now.addingTimeInterval(-20)))
        }
        return turns
    }

    /// AskUserQuestion input as Claude Code sends it (2 questions: single-select, then multi-select).
    static let questionInput: JSONValue = {
        let json = #"""
        {"questions":[
          {"question":"How should the pricing page show annual plans?","header":"Pricing","multiSelect":false,
           "options":[{"label":"Monthly price, billed yearly (Recommended)","description":"Shows $12/mo with \"billed yearly\" underneath, like most SaaS pages."},
                      {"label":"Total per year","description":"Shows $144/yr; honest, but the number looks bigger."},
                      {"label":"Both, with a toggle","description":"A Monthly / Yearly switch above the plan cards."}]},
          {"question":"Which extras should the pricing page have?","header":"Extras","multiSelect":true,
           "options":[{"label":"FAQ section","description":"Six common billing questions under the plan cards."},
                      {"label":"Comparison table","description":"Every feature per plan, with check marks."},
                      {"label":"Customer logos","description":"A strip of logos above the footer."}]}
        ]}
        """#
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .null
    }()

    static let questionInputSingle: JSONValue = {
        let json = #"""
        {"questions":[{"question":"The flaky checkout test fails 1 in 20 runs on a timezone edge case. What next?","header":"Next step","multiSelect":false,
          "options":[{"label":"Fix it now","description":"Pin the test clock to UTC and add a case for the date-line rollover."},
                     {"label":"Quarantine the test","description":"Mark it flaky so CI stays green, and open an issue."},
                     {"label":"Stop here","description":"Leave it as is and move on to the refunds endpoint."}]}]}
        """#
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .null
    }()

    /// A long plan (taller than the drop-down) for the plan demo.
    static let planText = """
    # Pricing page: annual toggle + comparison table

    ## Context
    The pricing page only lists monthly prices, and visitors keep asking support which features \
    each plan includes. Annual billing exists in the API but isn't shown anywhere.

    ## Plan
    1. **Billing toggle.** Add a Monthly / Yearly switch above the plan cards; yearly prices come \
    from the existing `GET /api/plans?interval=year` endpoint.
    2. **Comparison table.** One row per feature, one column per plan, check marks for included features.
    3. **FAQ.** Six billing questions in an accordion under the table.
    4. **Analytics.** Track toggle changes and plan clicks with the existing `track()` helper.

    ## Files
    - `apps/web/pages/pricing.tsx`: toggle, table, FAQ
    - `apps/web/components/PlanCard.tsx`: yearly price + "billed yearly" note
    - `apps/web/lib/plans.ts`: fetch both intervals

    ```ts
    const [interval, setInterval] = useState<"month" | "year">("year");
    const plans = usePlans(interval);
    ```

    ## Verification
    - Toggle Monthly / Yearly: every card updates without a reload.
    - The table matches the plan features in the admin.
    - Lighthouse score stays above 95.
    """

    static func apply(_ state: String, to app: AppState) {
        let now = Date()
        func session(_ name: String, _ cwd: String, _ status: SessionStatus, minutes: Double, tokens: Int,
                     text: String? = nil) -> ClaudeSession {
            ClaudeSession(pid: Int32(40000 + name.count), shellPid: nil, sessionId: "demo-\(name)",
                          cwd: cwd, name: name, status: status,
                          // Idle sessions last did something a while ago (the row's time column).
                          startedAt: now.addingTimeInterval(-minutes * 60),
                          updatedAt: status == .busy ? now : now.addingTimeInterval(-minutes * 20),
                          tokens: TokenTotals(input: tokens / 10, cacheCreation: tokens / 2, output: tokens * 4 / 10,
                                              lastContext: tokens * 3 / 8),
                          model: "claude-opus-5-5", lastAssistantText: text)
        }
        let home = NSHomeDirectory()
        let web = home + "/code/acme-web", api = home + "/code/acme-api", docs = home + "/code/acme-docs"
        let finishedText = "Refactored the payment API and all 42 tests pass. Want me to also update the API docs?"
        func titled(_ s: ClaudeSession, _ t: String?) -> ClaudeSession { var s = s; s.title = t; return s }
        let busyAll = [
            titled(session("landing-page", web, .busy, minutes: 24, tokens: 212_000), "Hero section copy"),
            titled(session("api-refactor", api, .busy, minutes: 6.2, tokens: 48_200, text: finishedText), "Refactor payment API"),
            titled(session("docs-cleanup", docs, .idle, minutes: 63, tokens: 26_700), "Docs cleanup"),
        ]
        // A session from Claude Desktop's Code tab (focus activates Claude Desktop, no quick reply).
        var desktop = session("mobile-onboarding", home + "/code/acme-mobile", .idle, minutes: 35, tokens: 184_000,
                              text: "The new onboarding screens are in. Want me to add a skip button too?")
        desktop.host = .claudeDesktop
        desktop.title = "Onboarding flow polish"
        let usage = UsageSnapshot(windows: [
            UsageWindow(label: "session", percent: 2, resetsText: "Nov 19 at 12:30am (America/Los_Angeles)"),
            UsageWindow(label: "week (all models)", percent: state == "nearlimit" ? 91 : 42,
                        resetsText: "Nov 20 at 9pm (America/Los_Angeles)"),
            UsageWindow(label: "week (Fable)", percent: 21, resetsText: "Nov 20 at 9pm (America/Los_Angeles)"),
        ], fetchedAt: now, stale: false)

        // Missed-sessions demos: sessions that finished `ago` minutes ago while nobody looked.
        let prDone = "Removed 14 single-use helpers; all 212 tests pass. Want me to open a PR?"
        let webDone = "The new hero copy is live on the preview branch."
        func finish(_ list: [ClaudeSession], ids: [String], ago: Double) {
            var next = list
            for i in next.indices where ids.contains(next[i].sessionId) { next[i].status = .busy }
            app.updateSessions(next, now: now.addingTimeInterval(-ago * 60 - 1))
            for i in next.indices where ids.contains(next[i].sessionId) { next[i].status = .idle }
            app.updateSessions(next, now: now.addingTimeInterval(-ago * 60))
        }
        func missedSessions(busyThird: Bool, waitingFirst: Bool) -> [ClaudeSession] {
            [titled(session("api-refactor", api, .idle, minutes: 40, tokens: 48_200, text: waitingFirst ? prDone : "Removed 14 single-use helpers; all 212 tests pass."),
                    "Refactor payment API"),
             titled(session("landing-page", web, .idle, minutes: 90, tokens: 212_000, text: webDone), "Hero section copy"),
             titled(session("docs-cleanup", docs, busyThird ? .busy : .idle, minutes: 63, tokens: 26_700), "Docs cleanup")]
        }

        switch state {
        case "unseen", "unseen-working", "unseen-mixed", "expanded-unseen":
            let list = missedSessions(busyThird: state == "unseen-working", waitingFirst: state != "unseen" && state != "unseen-working")
            app.updateSessions(list, now: now.addingTimeInterval(-3600))
            app.updateUsage(usage)
            finish(list, ids: ["demo-api-refactor"], ago: 12)
            finish(list, ids: ["demo-landing-page"], ago: 4)
            app.dismissFinished()
            if state == "expanded-unseen" {
                func agent(_ id: String, _ desc: String, _ action: String, _ m: Double) -> SubagentInfo {
                    SubagentInfo(agentId: id, description: desc, model: "claude-opus-5-5", status: .running,
                                 startedAt: now.addingTimeInterval(-m * 60), lastWrite: now, lastAction: action)
                }
                app.updateSubagents(["demo-docs-cleanup": SessionSubagents(agents: [
                    agent("c1", "Verify dead code: invoices", "Grep: legacy_charge", 3.2),
                    agent("c2", "Check callers, items 1-7", "Bash: pytest -q tests/api", 2.1),
                    agent("c3", "Draft migration notes", "Write MIGRATION.md", 1.0),
                ])], now: now)
                app.expand()
            }
        case "away-reset":
            // Away 50m: the 5h window reset 9m ago (97% -> 0%), two sessions finished.
            let list = missedSessions(busyThird: true, waitingFirst: false)
            app.updateSessions(list, now: now.addingTimeInterval(-3600))
            func snap(_ pct: Int, _ reset: String, _ at: Date) -> UsageSnapshot {
                UsageSnapshot(windows: [UsageWindow(label: "session", percent: pct, resetsText: reset + " (America/Los_Angeles)"),
                                        UsageWindow(label: "week (all models)", percent: 46, resetsText: "Nov 28 at 9am (America/Los_Angeles)")],
                              fetchedAt: at, stale: false)
            }
            app.updateUsage(snap(97, "Nov 21 at 3:30pm", now.addingTimeInterval(-55 * 60)), now: now.addingTimeInterval(-55 * 60))
            app.setAway(since: now.addingTimeInterval(-50 * 60))
            finish(list, ids: ["demo-api-refactor"], ago: 31)
            app.updateUsage(snap(0, "Nov 21 at 8:30pm", now.addingTimeInterval(-9 * 60)), now: now.addingTimeInterval(-9 * 60))
            finish(list, ids: ["demo-landing-page"], ago: 4)
            app.setReturned(now: now)
        case "away":
            let list = missedSessions(busyThird: false, waitingFirst: false)
            app.updateSessions(list, now: now.addingTimeInterval(-3600))
            app.updateUsage(usage)
            app.setAway(since: now.addingTimeInterval(-20 * 60))
            finish(list, ids: ["demo-api-refactor"], ago: 12)
            finish(list, ids: ["demo-landing-page"], ago: 4)
            let input: JSONValue = .object(["command": .string("rm -rf build")])
            let req = PermissionRequest(sessionId: "demo-docs-cleanup", sessionName: "docs-cleanup", cwd: docs, toolName: "Bash",
                                        summary: "rm -rf build", toolInput: input, raw: .null,
                                        receivedAt: now.addingTimeInterval(-7 * 60))
            app.enqueuePermission(req) { _ in }
            app.resolvePermission(id: req.id, decision: .ask)
            app.setReturned(now: now)
        case "reader-desktop":
            app.updateSessions(busyAll + [desktop])
            app.updateUsage(usage)
            app.openReader(sessionId: desktop.sessionId)
        case "finished-desktop":
            var d = desktop; d.status = .busy
            app.updateSessions(busyAll + [d])
            app.updateUsage(usage)
            d.status = .idle
            app.updateSessions(busyAll + [d])
        case "reader", "reader-working":
            var list = busyAll
            list[1].title = "Refactor payment API"
            list[1].status = state == "reader-working" ? .busy : .idle
            app.updateSessions(list)
            app.updateUsage(usage)
            app.openReader(sessionId: "demo-api-refactor")
        case "idle":
            app.updateSessions(busyAll.map { var s = $0; s.status = .idle; return s })
            app.updateUsage(usage)
        case "empty":
            // No sessions: the one-sided pill (no "0" on the right).
            app.updateUsage(usage)
        case "finished":
            app.updateSessions(busyAll)
            app.updateUsage(usage)
            var next = busyAll
            next[1].status = .idle
            app.updateSessions(next)
        case "finished-stack":
            // Two sessions finish a moment apart: the second card stacks under the first.
            app.updateSessions(busyAll)
            app.updateUsage(usage)
            var next = busyAll
            next[1].status = .idle
            app.updateSessions(next)
            next[0].status = .idle
            next[0].lastAssistantText = webDone
            app.updateSessions(next)
        case "permission":
            app.updateSessions(busyAll)
            app.updateUsage(usage)
            let input: JSONValue = .object(["command": .string("npm test -- --watch=false src/api")])
            let req = PermissionRequest(sessionId: "demo-api-refactor", sessionName: "api-refactor", cwd: api,
                                        toolName: "Bash",
                                        summary: PermissionRequest.summarize(toolName: "Bash", toolInput: input),
                                        toolInput: input, raw: .null)
            app.enqueuePermission(req) { print("demo permission decision: \($0)") }
        case "question", "question-multi", "question-single":
            var list = busyAll
            list[0].title = "Pricing page redesign"
            app.updateSessions(list)
            app.updateUsage(usage)
            let input = state == "question-single" ? questionInputSingle : questionInput
            let raw = JSONValue.object(["tool_name": .string("AskUserQuestion"), "tool_input": input])
            let req = PermissionRequest(sessionId: "demo-landing-page", sessionName: "landing-page", cwd: web,
                                        toolName: "AskUserQuestion", summary: "", toolInput: input, raw: raw)
            app.enqueuePermission(req) { print("demo question decision: \($0.hookResponse)") }
        case "plan", "plan-feedback":
            var list = busyAll
            list[0].title = "Pricing page redesign"
            app.updateSessions(list)
            app.updateUsage(usage)
            let input = JSONValue.object(["plan": .string(planText),
                                          "planFilePath": .string(home + "/.claude/plans/pricing-page-toggle.md")])
            let raw = JSONValue.object(["tool_name": .string("ExitPlanMode"), "tool_input": input])
            let req = PermissionRequest(sessionId: "demo-landing-page", sessionName: "landing-page", cwd: web,
                                        toolName: "ExitPlanMode", summary: "", toolInput: input, raw: raw)
            app.enqueuePermission(req) { print("demo plan decision: \($0.hookResponse)") }
        case "expanded-side":
            // Claude Desktop side sessions under the session that started them; one just finished.
            func side(_ s: ClaudeSession, _ local: String, _ title: String, parent: String? = nil) -> ClaudeSession {
                var s = s
                s.host = .claudeDesktop
                s.desktop = DesktopSessionInfo(localId: local, title: title, parentLocalId: parent,
                                               parentTitle: parent == nil ? nil : "Onboarding flow polish")
                return s
            }
            let mobile = home + "/code/acme-mobile"
            let parent = side(desktop, "local_demo_p", "Onboarding flow polish")
            let icons = side(session("mobile-icons", mobile, .busy, minutes: 12, tokens: 61_000,
                                     text: "The app icon set and splash screen are exported. Want me to add them to the README?"),
                             "local_demo_i", "App icon and splash screen", parent: "local_demo_p")
            let docs2 = side(session("mobile-docs", mobile, .busy, minutes: 8, tokens: 33_000),
                             "local_demo_d", "Privacy policy and store listing", parent: "local_demo_p")
            let list = busyAll + [parent, icons, docs2]
            app.updateSessions(list, now: now.addingTimeInterval(-600))
            app.updateUsage(usage)
            finish(list, ids: ["demo-mobile-icons"], ago: 2)
            app.dismissFinished()
            app.expand()
        case "expanded", "expanded-desktop":
            app.updateSessions(busyAll + [desktop])
            app.updateUsage(usage)
            app.updateSubagents(demoSubagents(now: now), now: now)
            app.expand()
        case "reset-before", "usage-reset", "reset-week-before", "usage-reset-week":
            // Usage reset demos: the 5h session (97% -> 0%) or the weekly window (88% -> 3%).
            let week = state.contains("week")
            func snap(_ before: Bool) -> UsageSnapshot {
                UsageSnapshot(windows: [
                    UsageWindow(label: "session", percent: week ? 12 : (before ? 97 : 0),
                                resetsText: !week && !before ? "Nov 21 at 8:30pm (America/Los_Angeles)" : "Nov 21 at 3:30pm (America/Los_Angeles)"),
                    UsageWindow(label: "week (all models)", percent: week ? (before ? 88 : 3) : 42,
                                resetsText: week && !before ? "Nov 28 at 9am (America/Los_Angeles)" : "Nov 21 at 9am (America/Los_Angeles)"),
                ], fetchedAt: now, stale: false)
            }
            app.updateSessions(busyAll)
            app.updateUsage(snap(true))
            if !state.hasSuffix("before") { app.updateUsage(snap(false)) }
        default: // working, nearlimit
            var s = busyAll
            if state == "nearlimit" { s[0].status = .idle }
            app.updateSessions(s)
            app.updateUsage(usage)
        }
    }
}

import AppKit
import SwiftUI

extension DemoMode {
    static let longReply = "Yes, go ahead and open the PR, but first:\n- rename chargeLegacy to chargeCard everywhere\n- keep the old endpoint behind a flag for one release so the mobile app doesn't break\nThen ping me with the PR link and a short summary of what changed."

    /// Render-only variants: long multi-line reply drafts and hover-revealed rows.
    @MainActor
    static func applyRenderVariant(_ state: String, app: AppState, ui: NotchUIState) {
        switch state {
        case "reader-reply":
            ReplyFieldMetrics.setDraft(longReply, slot: ReaderMetrics.replySlot("demo-api-refactor"),
                                       fieldWidth: ReaderMetrics.replyFieldWidth, ui: ui)
        case "expanded-reply":
            ui.replyTargetId = "demo-api-refactor"
            ReplyFieldMetrics.setDraft(longReply, slot: ExpandedMetrics.replySlot("demo-api-refactor"),
                                       fieldWidth: ExpandedMetrics.replyFieldWidth, ui: ui)
        case "finished-reply":
            ReplyFieldMetrics.setDraft("Great, thanks!\nNow update the API docs too, and add a changelog entry for the payment refactor.",
                                       slot: FinishedView.replySlot("demo-api-refactor"),
                                       fieldWidth: FinishedView.replyFieldWidth,
                                       target: "api-refactor", ui: ui)
        case "expanded-reveal":
            var list = app.sessions
            if let i = list.firstIndex(where: { $0.sessionId == "demo-docs-cleanup" }) {
                list[i].title = "Docs cleanup: consolidate the API reference, fix every broken link and move the guides to the new docs site"
                app.updateSessions(list)
            }
            ui.forceReveal("demo-docs-cleanup")
        case "expanded-unseen-reveal":
            var list = app.sessions
            if let i = list.firstIndex(where: { $0.sessionId == "demo-api-refactor" }) {
                list[i].title = "Refactor the payment API and remove the legacy charge helpers"
                list[i].lastAssistantText = "Removed 14 single-use helpers and moved the retry logic into PaymentClient, all 212 tests pass and the coverage went up to 91%. Want me to open a PR with these changes?"
                app.updateSessions(list)
            }
            ui.forceReveal("demo-api-refactor")
        default: break
        }
    }
}

/// `Turnipot --render=<dir>`: render every demo state offscreen to PNGs (no window, no screen
/// recording permission needed) for checking layout against the mockups.
@MainActor
enum RenderCommand {
    static var requestedDir: String? {
        CommandLine.arguments.first { $0.hasPrefix("--render=") }.map { String($0.dropFirst("--render=".count)) }
    }

    static func run(dir: String) -> Never {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let geo = NotchGeometry(screenFrame: screen,
                                notchRect: CGRect(x: screen.midX - 92.5, y: screen.maxY - 32, width: 185, height: 32),
                                hasNotch: true)
        var states = ["idle", "empty", "working", "finished", "permission", "nearlimit", "expanded",
                      "expanded-reveal", "expanded-unseen-reveal", "expanded-reply", "reader-reply", "finished-reply",
                      "unseen", "unseen-working", "unseen-mixed", "expanded-unseen", "away",
                      "reader", "reader-working", "expanded-desktop", "expanded-side", "finished-desktop", "reader-desktop",
                      "finished-stack", "finished-stack-frozen",
                      "question", "question-multi", "question-single", "plan", "plan-feedback"]
        states.append(contentsOf: ["confirmation", "prompt-hook", "update-notice", "finished-dialog"])
        for state in states {
            let app = AppState()
            // Render-only variants of a demo state (reply drafts, hover-revealed rows).
            let base: String
            switch state {
            case "confirmation", "prompt-hook", "update-notice": base = "working"
            case "finished-dialog": base = "finished"
            case "expanded-reveal", "expanded-reply": base = "expanded"
            case "expanded-unseen-reveal": base = "expanded-unseen"
            case "reader-reply": base = "reader"
            case "finished-reply": base = "finished"
            case "finished-stack-frozen": base = "finished-stack"
            default: base = state
            }
            DemoMode.apply(base, to: app)
            let ui = NotchUIState(geometry: geo)
            DemoMode.applyRenderVariant(state, app: app, ui: ui)
            if state.hasPrefix("reader") {
                ui.readerTurns = DemoMode.readerTurns(working: state == "reader-working")
                ui.readerTurnsSessionId = state == "reader-desktop" ? "demo-mobile-onboarding" : "demo-api-refactor"
            }
            if state == "expanded-desktop" { ui.replyTargetId = "demo-mobile-onboarding" }   // its ↩ slot
            // Hovering the first card when the second session finished: frozen, "+1 more".
            if state == "finished-stack-frozen" { ui.stickyFinishedIds = ["demo-api-refactor"] }
            if let req = app.currentPermission {
                switch state {
                case "question":         // step 1/2, first option picked
                    ui.updateDraft(for: req) { $0.selections[0].toggle(0, multiSelect: false) }
                case "question-multi":   // step 2/2 (multi-select), two picks + "Other…" open
                    ui.updateDraft(for: req) { d in
                        d.selections[0].toggle(0, multiSelect: false)
                        d.step = 1
                        d.selections[1].toggle(0, multiSelect: true)
                        d.selections[1].toggle(1, multiSelect: true)
                        d.otherOpen.insert(1)
                        d.selections[1].other = "A note about the student discount"
                    }
                case "plan-feedback":
                    ui.planFeedbackRequestId = req.id
                    ui.planFeedbackText = "Keep the toggle's choice in the URL"
                default: break
                }
            }
            if state == "confirmation" { ui.confirm("✓ Sent to api-refactor", detail: "“yes, and open a PR”", tone: .ok) }
            if state == "prompt-hook" {
                ui.prompt("Install the Claude Code hook?", detail: "Answer permissions, questions and plans from the notch",
                          lines: ["Adds a PermissionRequest hook to ~/.claude/settings.json (a backup is saved first):",
                                  "   /Applications/Turnipot.app/Contents/Helpers/turnipot-hook",
                                  "Replaces the earlier Turnipot hook: ~/code/turnipot/build/Turnipot.app/Contents/Helpers/turnipot-hook",
                                  "Keeps 1 other PermissionRequest hook and everything else."],
                          actions: [.init(title: "Cancel"), .init(title: "Install", role: .primary)])
            }
            if state == "update-notice" {
                ui.prompt("Turnipot v0.4.0 is available", detail: "You have v0.3.0 · also in ⚙ → Update available",
                          actions: [.init(title: "Later"), .init(title: "Download", role: .primary)])
            }
            if state == "finished-dialog", let sid = app.latestFinishedSessionId {
                // A request handed back to the terminal: quick reply is paused for the session.
                let r = PermissionRequest(sessionId: sid, toolName: "Bash", summary: "ls", toolInput: .null, raw: .null)
                app.enqueuePermission(r) { _ in }
                app.resolvePermission(id: r.id, decision: .ask)
            }
            let size = geo.panelFrame.size
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x3b2a5a), Color(hex: 0x1d4b5c)], startPoint: .bottomLeading, endPoint: .topTrailing)
                Rectangle().fill(Color.black.opacity(0.18)).frame(height: 32)
                IslandView(appState: app, ui: ui)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.notchStaticRender, true)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                let out = url.appendingPathComponent("\(state).png")
                try? png.write(to: out)
                print(out.path)
            } else {
                print("render failed: \(state)")
            }
        }
        renderAnimationFrames(dir: url.appendingPathComponent("anim", isDirectory: true), geo: geo)
        // Also check the Core Animation mascot's layer geometry (model layer, no animation).
        for (i, mood) in MascotMood.allCases.enumerated() {
            let v = TurnipNSView(pixelSize: 10, layout: .compact)
            v.apply(mood: mood, showZ: true, extended: true, usage: 42)
            func strip(_ l: CALayer) { l.removeAllAnimations(); l.sublayers?.forEach(strip) }
            if let l = v.layer { strip(l) }
            let fs = TurnipMascotView.frameSize(pixelSize: 10, layout: .compact)
            let w = Int(fs.width) + 20, h = Int(fs.height) + 20
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            if let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext, let layer = v.layer {
                ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.translateBy(x: 10, y: CGFloat(h) - 10); ctx.scaleBy(x: 1, y: -1)   // top-left origin like a window
                ctx.setStrokeColor(NSColor.darkGray.cgColor)   // mascot frame (its top = the island's top edge)
                ctx.stroke(CGRect(origin: .zero, size: fs).insetBy(dx: -0.5, dy: -0.5))
                if !layer.isGeometryFlipped { ctx.translateBy(x: 0, y: fs.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
            }
            let out = url.appendingPathComponent("layer-\(i)-\(mood.rawValue).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print(out.path, "flipped:", v.layer?.isGeometryFlipped ?? false)
        }
        exit(0)
    }

    /// Frames of the island animations at several progress values (p = 0 ... 1 of each
    /// sequence's duration), computed with the same springs/timings the live view uses:
    /// anim/<sequence>-<p>.png. The physical notch is drawn dark grey here (it is black on a real
    /// screen) so the black island can be told apart from it.
    static func renderAnimationFrames(dir: URL, geo: NotchGeometry) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        typealias M = IslandMotion
        let hidden = IslandShapeState.hidden(geo)
        let progressValues: [Double] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0]

        struct Sequence {
            var name: String
            var demo: String
            var duration: Double
            var frame: (_ t: Double, _ app: AppState, _ ui: NotchUIState) -> IslandFrameOverride
        }

        @MainActor func shapeOf(_ p: Presentation, _ app: AppState, _ ui: NotchUIState) -> IslandShapeState {
            IslandShapeState(size: p.bodySize(appState: app, ui: ui), radius: p.bottomRadius,
                             rightTrim: p.rightTrim(appState: app))
        }
        /// The pill as it looks for this demo state (wing width depends on counts / unseen badge).
        @MainActor func collapsedOf(_ app: AppState, _ ui: NotchUIState) -> Presentation {
            .collapsed(wing: PillLayout.wing(appState: app, ui: ui))
        }

        /// Grow from `from` to `to`: old content fades out, shape springs (overshoot), new content
        /// slides/fades in after contentInDelay.
        @MainActor func grow(_ from: Presentation, _ to: Presentation, t: Double, app: AppState, ui: NotchUIState) -> IslandFrameOverride {
            let f = M.progress(M.growSpring, t: t)
            let shape = shapeOf(from, app, ui).interpolated(to: shapeOf(to, app, ui), f)
            if t < M.contentOutDuration {
                return IslandFrameOverride(shape: shape, content: from, contentOpacity: 1 - t / M.contentOutDuration,
                                           transitionOnly: true)
            }
            let c = M.contentInProgress(t: t)
            return IslandFrameOverride(shape: shape, content: to, contentOpacity: c,
                                       contentScale: 0.94 + 0.06 * CGFloat(c), contentOffset: -6 * CGFloat(1 - c),
                                       transitionOnly: true)
        }
        /// Shrink: content fades out first, then the shape retracts (delayed, low-bounce spring).
        @MainActor func shrink(_ from: Presentation, _ to: Presentation, t: Double, app: AppState, ui: NotchUIState) -> IslandFrameOverride {
            let f = M.progress(M.shrinkSpring, t: t, delay: M.shrinkDelay)
            let shape = shapeOf(from, app, ui).interpolated(to: shapeOf(to, app, ui), f)
            if t < M.contentOutDuration {
                return IslandFrameOverride(shape: shape, content: from, contentOpacity: 1 - t / M.contentOutDuration,
                                           transitionOnly: true)
            }
            let c = M.contentInProgress(t: t)
            return IslandFrameOverride(shape: shape, content: to, contentOpacity: c,
                                       contentScale: 0.94 + 0.06 * CGFloat(c), contentOffset: -6 * CGFloat(1 - c),
                                       transitionOnly: true)
        }

        var sequences: [Sequence] = [
            // Launch: pill springs out, content fades in, then the turnip rises out of its pot.
            Sequence(name: "launch", demo: "working", duration: 1.0) { t, app, ui in
                let f = M.progress(M.launchSpring, t: t)
                let c = M.contentInProgress(t: t)
                return IslandFrameOverride(shape: hidden.interpolated(to: shapeOf(collapsedOf(app, ui), app, ui), f),
                                           content: collapsedOf(app, ui), contentOpacity: c, contentScale: 0.92 + 0.08 * CGFloat(c),
                                           mascotExtension: M.progress(M.mascotDropSpring, t: t, delay: M.mascotDropDelay))
            },
            // Quit: the turnip sinks into its pot first, then the content fades and the pill retracts.
            Sequence(name: "quit", demo: "working", duration: 0.7) { t, app, ui in
                let up = M.mascotPullUpDuration
                let f = M.progress(M.retractSpring, t: t, delay: up + M.contentOutDuration)
                return IslandFrameOverride(shape: shapeOf(collapsedOf(app, ui), app, ui).interpolated(to: hidden, f),
                                           content: collapsedOf(app, ui),
                                           contentOpacity: min(1, max(0, 1 - (t - up) / M.contentOutDuration)),
                                           mascotExtension: 1 - M.progress(M.mascotPullUpSpring, t: t))
            },
            Sequence(name: "expand", demo: "expanded", duration: 0.7) { t, app, ui in
                grow(collapsedOf(app, ui), .expanded, t: t, app: app, ui: ui)
            },
            Sequence(name: "collapse", demo: "expanded", duration: 0.7) { t, app, ui in
                shrink(.expanded, collapsedOf(app, ui), t: t, app: app, ui: ui)
            },
            Sequence(name: "permission", demo: "permission", duration: 0.7) { t, app, ui in
                grow(collapsedOf(app, ui), Presentation.current(appState: app, ui: ui), t: t, app: app, ui: ui)
            },
            Sequence(name: "permission-dismiss", demo: "permission", duration: 0.7) { t, app, ui in
                shrink(Presentation.current(appState: app, ui: ui), collapsedOf(app, ui), t: t, app: app, ui: ui)
            },
            Sequence(name: "finished", demo: "finished", duration: 0.7) { t, app, ui in
                grow(collapsedOf(app, ui), Presentation.current(appState: app, ui: ui), t: t, app: app, ui: ui)
            },
            // Expanded panel -> reply reader (same width, taller): the island grows downward.
            Sequence(name: "reader", demo: "reader", duration: 0.7) { t, app, ui in
                ui.readerTurns = DemoMode.readerTurns()
                ui.readerTurnsSessionId = "demo-api-refactor"
                return grow(.expanded, .reader(sessionId: "demo-api-refactor"), t: t, app: app, ui: ui)
            },
        ]
        // Turnip: the finished drop-down's spring-out (one jump), and the small pop in the pill.
        do {
            sequences.append(Sequence(name: "spring", demo: "finished", duration: TurnipRig.springDuration) { t, app, ui in
                let p = Presentation.current(appState: app, ui: ui)
                var o = IslandFrameOverride(shape: shapeOf(p, app, ui), content: p, contentOpacity: 1)
                o.mascotTime = t
                return o
            })
            sequences.append(Sequence(name: "hop", demo: "finished", duration: TurnipRig.hopDuration) { t, app, ui in
                var o = IslandFrameOverride(shape: shapeOf(collapsedOf(app, ui), app, ui), content: collapsedOf(app, ui), contentOpacity: 1)
                o.mascotTime = t
                return o
            })
        }

        let size = geo.panelFrame.size
        let notchX = geo.notchRect.minX - geo.panelFrame.minX
        for seq in sequences {
            let app = AppState()
            DemoMode.apply(seq.demo, to: app)
            let ui = NotchUIState(geometry: geo)
            for p in progressValues {
                let t = p * seq.duration
                let override = seq.frame(t, app, ui)
                let view = ZStack(alignment: .topLeading) {
                    LinearGradient(colors: [Color(hex: 0x3b2a5a), Color(hex: 0x1d4b5c)], startPoint: .bottomLeading, endPoint: .topTrailing)
                    Rectangle().fill(Color.black.opacity(0.18)).frame(height: geo.notchHeight)
                    UnevenRoundedRectangle(bottomLeadingRadius: NotchGeometry.collapsedBottomRadius,
                                           bottomTrailingRadius: NotchGeometry.collapsedBottomRadius)
                        .fill(Color(white: 0.25))
                        .frame(width: geo.notchRect.width, height: geo.notchHeight)
                        .offset(x: notchX)
                    IslandView(appState: app, ui: ui, frameOverride: override)
                }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.notchStaticRender, true)
                let r = ImageRenderer(content: view)
                r.scale = 2
                let name = "\(seq.name)-\(String(format: "%.1f", p)).png"
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(name))
                    print(dir.appendingPathComponent(name).path,
                          String(format: "body %.1fx%.1f r=%.1f s=%.1f content=%@ a=%.2f",
                                 override.shape.size.width, override.shape.size.height, override.shape.radius,
                                 override.shape.shoulder,
                                 override.content.kind, override.contentOpacity))
                } else {
                    print("render failed: \(name)")
                }
            }
        }
    }
}
