import SwiftUI
import AppKit
import NotchCore

// AskUserQuestion and ExitPlanMode drop-downs. They share the permission queue (oldest first),
// the amber "needs you" glow and the shaking mascot; answers go back through turnipot-hook as
// documented `updatedInput` (see HookOutput / CONTRACTS.md).

// MARK: - Layout

/// Content-driven height of the question drop-down (measured with the view's fonts), capped at
/// `NotchGeometry.readerMaxHeight`; the question + options area scrolls when it doesn't fit.
enum QuestionMetrics {
    static let sidePad: CGFloat = 18
    static let topPad: CGFloat = 2
    static let titleRow: CGFloat = 22
    static let titleGap: CGFloat = 8
    static let headerRow: CGFloat = 18
    static let questionSize: CGFloat = 14
    static let optionsGap: CGFloat = 10
    static let optionSpacing: CGFloat = 4
    static let optionVPad: CGFloat = 7
    static let labelLine: CGFloat = 17
    static let descSize: CGFloat = 12
    static let otherClosed: CGFloat = 32
    static let otherOpen: CGFloat = 38
    static let footerGap: CGFloat = 12
    static let footer: CGFloat = 34
    static let bottomPad: CGFloat = 14
    /// Option row: 12 left pad + 18 key badge + 8 + 14 glyph + 8 ... + 12 right pad.
    static let optionChrome: CGFloat = 72
    static var textWidth: CGFloat { NotchGeometry.questionWidth - 2 * sidePad }

    static var chrome: CGFloat { topPad + titleRow + titleGap + footerGap + footer + bottomPad }

    @MainActor
    static func height(request: PermissionRequest, ui: NotchUIState) -> CGFloat {
        let strip = ui.geometry.notchHeight
        guard let qs = request.questions, !qs.isEmpty else { return strip + 160 }
        let d = ui.draft(for: request)
        let step = min(max(d.step, 0), qs.count - 1)
        let body = scrollContentHeight(qs[step], otherOpen: d.otherOpen.contains(step))
        return min(ui.geometry.readerMaxHeight, ceil(strip + chrome + body))
    }

    /// Height of the question + options block (the part that scrolls when too tall).
    @MainActor
    static func scrollContentHeight(_ q: AskQuestion, otherOpen: Bool) -> CGFloat {
        var h: CGFloat = q.header.isEmpty ? 0 : headerRow
        h += ReaderMetrics.measure(q.question, font: NSFont.systemFont(ofSize: questionSize, weight: .semibold),
                                   width: textWidth, spacing: 2)
        h += optionsGap
        for o in q.options { h += optionHeight(o) + optionSpacing }
        h += otherOpen ? Self.otherOpen : Self.otherClosed
        return h + 4
    }

    static func optionHeight(_ o: AskOption) -> CGFloat {
        let w = textWidth - optionChrome
        var h = 2 * optionVPad + max(labelLine, ReaderMetrics.measure(o.label, font: NSFont.systemFont(ofSize: 13, weight: .semibold), width: w, spacing: 1))
        if !o.description.isEmpty {
            h += 2 + ReaderMetrics.measure(o.description, font: NSFont.systemFont(ofSize: descSize), width: w, spacing: 1.5)
        }
        return h
    }
}

/// Plan drop-down height: the plan's Markdown measured like the reader, capped at
/// `NotchGeometry.readerMaxHeight` (the plan scrolls).
enum PlanMetrics {
    static let topPad: CGFloat = 2
    static let titleRow: CGFloat = 26
    static let feedback: CGFloat = 42
    static let feedbackGap: CGFloat = 8
    static let footerGap: CGFloat = 10
    static let footer: CGFloat = 34
    static let bottomPad: CGFloat = 14
    static let minHeight: CGFloat = 220

    @MainActor
    static func height(request: PermissionRequest, ui: NotchUIState) -> CGFloat {
        let strip = ui.geometry.notchHeight
        let text = request.plan?.plan ?? ""
        let fb = ui.planFeedbackRequestId == request.id ? feedback + feedbackGap : 0
        let content = ReaderMetrics.contentHeight(text) + ReaderMetrics.scrollTopPad + ReaderMetrics.scrollBottomPad
        let h = strip + topPad + titleRow + content + fb + footerGap + footer + bottomPad
        return min(ui.geometry.readerMaxHeight, max(minHeight, ceil(h)))
    }
}

// MARK: - Actions (shared by the buttons and the hot keys)

@MainActor
enum QuestionActions {
    /// Submit when every question is answered.
    static func submit(appState: AppState, ui: NotchUIState, request: PermissionRequest) {
        guard ui.needsYouActionAllowed(request.id) else { return }   // FreshContentGate (400 ms)
        guard let qs = request.questions else { return }
        let d = ui.draft(for: request)
        guard let answers = QuestionAnswers.answers(qs, d.selections) else { return }
        let input = QuestionAnswers.updatedInput(original: request.toolInput, answers: answers)
        ui.questionDraft = nil
        if ui.isEditing { ui.releaseKey() }
        appState.resolvePermission(id: request.id, decision: .answer(updatedInput: input))
        let detail = qs.count == 1 ? answers[qs[0].question].map { "“\($0)”" } : "\(qs.count) answers"
        ui.confirm("✓ Answered", detail: detail, tone: .ok)
    }

    /// ⌘↩ / Return in "Other…": next step when the current question is answered, submit on the last.
    static func primary(appState: AppState, ui: NotchUIState, request: PermissionRequest) {
        guard ui.needsYouActionAllowed(request.id) else { return }   // FreshContentGate (400 ms)
        guard let qs = request.questions else { return }
        let d = ui.draft(for: request)
        let step = min(d.step, qs.count - 1)
        guard d.selections.indices.contains(step), d.selections[step].isAnswered else { return }
        if step < qs.count - 1 {
            withAnimation(.spring(IslandMotion.growSpring)) { ui.updateDraft(for: request) { $0.step = step + 1 } }
        } else {
            submit(appState: appState, ui: ui, request: request)
        }
    }

    /// 1-9 (hot keys while hovered) and clicks: pick option `index` of the current question;
    /// index == options.count is "Other…" (opens the text field).
    static func pick(_ index: Int, appState: AppState, ui: NotchUIState, request: PermissionRequest) {
        guard ui.needsYouActionAllowed(request.id) else { return }   // FreshContentGate (400 ms)
        guard let qs = request.questions else { return }
        let d = ui.draft(for: request)
        let step = min(d.step, qs.count - 1)
        let q = qs[step]
        if index == q.options.count {
            ui.updateDraft(for: request) { $0.otherOpen.insert(step) }
            return
        }
        guard q.options.indices.contains(index) else { return }
        ui.updateDraft(for: request) { d in
            d.selections[step].toggle(index, multiSelect: q.multiSelect)
            if !q.multiSelect { d.otherOpen.remove(step) }
        }
    }

    /// "Answer in terminal ↗" / esc: Claude Code shows its own prompt; focus the session.
    static func answerInTerminal(appState: AppState, ui: NotchUIState, request: PermissionRequest) {
        guard ui.needsYouActionAllowed(request.id) else { return }   // FreshContentGate (400 ms)
        ui.questionDraft = nil
        ui.planFeedbackRequestId = nil
        if ui.isEditing { ui.releaseKey() }
        let desktop = appState.session(id: request.sessionId)?.isClaudeDesktop == true
        appState.openPermissionInTerminal(id: request.id)
        ui.confirm(desktop ? "↗ Opened Claude Desktop" : "↗ Answer in the terminal", tone: .neutral)
    }

    static func approvePlan(_ mode: PlanApprovalMode, appState: AppState, ui: NotchUIState, request: PermissionRequest) {
        guard ui.needsYouActionAllowed(request.id) else { return }   // FreshContentGate (400 ms)
        ui.planFeedbackRequestId = nil
        if ui.isEditing { ui.releaseKey() }
        appState.resolvePermission(id: request.id, decision: .approvePlan(updatedInput: request.toolInput, mode: mode))
        ui.confirm("✓ Plan approved", detail: mode == .manual ? nil : mode.title.replacingOccurrences(of: "Approve, ", with: ""), tone: .ok)
    }

    static func sendPlanFeedback(appState: AppState, ui: NotchUIState, request: PermissionRequest) {
        guard ui.needsYouActionAllowed(request.id) else { return }   // FreshContentGate (400 ms)
        let text = ui.planFeedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ui.planFeedbackRequestId = nil
        ui.planFeedbackText = ""
        if ui.isEditing { ui.releaseKey() }
        appState.resolvePermission(id: request.id, decision: .denyWithMessage(PlanContent.feedbackMessage(text)))
        ui.confirm("↩ Keep planning", detail: "“\(text)”", tone: .neutral)
    }
}

// MARK: - Shared parts

/// Notch strip of the "needs you" drop-downs: shaking mascot left, "+N more" and the amber dot right.
struct NeedsYouStrip: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var ui: NotchUIState

    var body: some View {
        NotchStrip(height: ui.geometry.notchHeight) {
            MascotView(mood: .shake, pixelSize: MascotView.pixelSize(forStrip: ui.geometry.notchHeight))
        } trailing: {
            if appState.pendingPermissions.count > 1 {
                Text("+\(appState.pendingPermissions.count - 1) more")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.amber)
            }
            StatusDot(color: Theme.amber, pulse: true, period: 0.9)
        }
    }
}

/// Single-line text field for the drop-downs (no send button). Takes key status on click like
/// ReplyField; Return calls `onSubmit`.
struct InlineTextField: View {
    var placeholder: String
    @Binding var text: String
    var autoFocus = false
    var onSubmit: () -> Void

    @EnvironmentObject private var ui: NotchUIState
    @FocusState private var focused: Bool
    @Environment(\.notchStaticRender) private var staticRender

    var body: some View {
        Group {
            if staticRender {
                Text(text.isEmpty ? placeholder : text)
                    .font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? Theme.muted.opacity(0.7) : .white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit(onSubmit)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(focused ? Theme.amber.opacity(0.6) : Theme.cardBorder, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
        .onChange(of: focused) { _, f in ui.isEditing = f }
        .onChange(of: ui.focusRequest) { _, _ in if !focused { focused = true } }
        .onAppear { if autoFocus && !staticRender { beginEditing() } }
    }

    private func beginEditing() {
        ui.requestKey()
        DispatchQueue.main.async { focused = true }
    }
}

/// "<title>  <verb>" header line of the drop-downs.
struct NeedsYouTitle: View {
    let title: String
    let verb: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Text(verb).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.amber).fixedSize()
            }
        }
        .help(title)
    }
}

@MainActor private func sessionTitle(_ appState: AppState, _ request: PermissionRequest) -> String {
    appState.session(id: request.sessionId)?.displayTitle ?? request.sessionName ?? "Claude"
}

// MARK: - Question drop-down

/// AskUserQuestion: session title, "1/2" step, the question's header + text, options as rows
/// (key number, radio / checkbox, bold label + muted description), "Other…" free text, and
/// ‹ Back / Next › / Submit ⌘↩ · Answer in terminal ↗. 1-9 pick options while hovered.
struct QuestionView: View {
    @ObservedObject var appState: AppState
    let request: PermissionRequest
    @EnvironmentObject private var ui: NotchUIState
    @Environment(\.notchStaticRender) private var staticRender

    var body: some View {
        let qs = request.questions ?? []
        let d = ui.draft(for: request)
        let step = qs.isEmpty ? 0 : min(max(d.step, 0), qs.count - 1)
        let total = QuestionMetrics.height(request: request, ui: ui)
        let available = total - ui.geometry.notchHeight - QuestionMetrics.chrome

        VStack(alignment: .leading, spacing: 0) {
            NeedsYouStrip(appState: appState)
            VStack(alignment: .leading, spacing: 0) {
                NeedsYouTitle(title: sessionTitle(appState, request),
                              verb: qs.count > 1 ? "asks you \(qs.count) questions" : "asks you",
                              trailing: qs.count > 1 ? "\(step + 1)/\(qs.count)" : nil)
                    .frame(height: QuestionMetrics.titleRow)
                    .padding(.bottom, QuestionMetrics.titleGap)
                if !qs.isEmpty {
                    ReaderScroll(staticRender: staticRender) {
                        questionBody(qs[step], step: step, draft: d)
                    }
                    .frame(height: max(0, available))
                    .id("\(request.id)-\(step)")
                }
                footer(qs: qs, step: step, draft: d)
                    .frame(height: QuestionMetrics.footer)
                    .padding(.top, QuestionMetrics.footerGap)
            }
            .padding(.horizontal, QuestionMetrics.sidePad)
            .padding(.top, QuestionMetrics.topPad)
            .padding(.bottom, QuestionMetrics.bottomPad)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func questionBody(_ q: AskQuestion, step: Int, draft d: NotchUIState.QuestionDraft) -> some View {
        let sel = d.selections.indices.contains(step) ? d.selections[step] : QuestionSelection()
        VStack(alignment: .leading, spacing: 0) {
            if !q.header.isEmpty {
                HStack(spacing: 6) {
                    Text(q.header.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(Theme.amber)
                    if q.multiSelect {
                        Text("· pick any").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(height: QuestionMetrics.headerRow, alignment: .topLeading)
            }
            Text(q.question)
                .font(.system(size: QuestionMetrics.questionSize, weight: .semibold))
                .foregroundStyle(.white)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.bottom, QuestionMetrics.optionsGap)
            VStack(alignment: .leading, spacing: QuestionMetrics.optionSpacing) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                    OptionRow(number: i + 1, label: o.label, detail: o.description, multi: q.multiSelect,
                              selected: sel.options.contains(i)) {
                        QuestionActions.pick(i, appState: appState, ui: ui, request: request)
                    }
                }
                otherRow(q, step: step, selection: sel, open: d.otherOpen.contains(step))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func otherRow(_ q: AskQuestion, step: Int, selection: QuestionSelection, open: Bool) -> some View {
        if open {
            HStack(spacing: 8) {
                Text("\(q.options.count + 1)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .frame(width: 18)
                InlineTextField(placeholder: "Type your own answer…",
                                text: Binding(get: { ui.draft(for: request).selections[step].other ?? "" },
                                              set: { v in ui.updateDraft(for: request) { d in
                                                  d.selections[step].other = v
                                                  if !q.multiSelect && !v.isEmpty { d.selections[step].options = [] }
                                              } }),
                                autoFocus: true) {
                    QuestionActions.primary(appState: appState, ui: ui, request: request)
                }
            }
            .padding(.leading, 12)
            .frame(height: QuestionMetrics.otherOpen - 4)
        } else {
            OptionRow(number: q.options.count + 1, label: "Other…", detail: "", multi: q.multiSelect,
                      selected: selection.trimmedOther != nil, muted: true) {
                QuestionActions.pick(q.options.count, appState: appState, ui: ui, request: request)
            }
            .frame(height: QuestionMetrics.otherClosed - QuestionMetrics.optionSpacing)
        }
    }

    @ViewBuilder private func footer(qs: [AskQuestion], step: Int, draft d: NotchUIState.QuestionDraft) -> some View {
        let answered = d.selections.indices.contains(step) && d.selections[step].isAnswered
        let last = step >= qs.count - 1
        let allAnswered = QuestionAnswers.answers(qs, d.selections) != nil
        HStack(spacing: 8) {
            if qs.count > 1 && step > 0 {
                Button {
                    withAnimation(.spring(IslandMotion.growSpring)) { ui.updateDraft(for: request) { $0.step = step - 1 } }
                } label: { Text("‹ Back") }
                .buttonStyle(NotchButtonStyle())
            }
            if last {
                Button { QuestionActions.submit(appState: appState, ui: ui, request: request) } label: {
                    HStack(spacing: 6) {
                        Text("Submit")
                        Text("⌘↩").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(NotchButtonStyle(background: Color(hex: 0x1f6f3c)))
                .opacity(allAnswered ? 1 : 0.45)
                .disabled(!allAnswered)
            } else {
                Button { QuestionActions.primary(appState: appState, ui: ui, request: request) } label: {
                    HStack(spacing: 6) {
                        Text("Next ›")
                        Text("⌘↩").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(NotchButtonStyle(background: Color(hex: 0x1f6f3c)))
                .opacity(answered ? 1 : 0.45)
                .disabled(!answered)
            }
            Spacer(minLength: 8)
            Button { QuestionActions.answerInTerminal(appState: appState, ui: ui, request: request) } label: {
                HStack(spacing: 6) {
                    Text(appState.session(id: request.sessionId)?.isClaudeDesktop == true ? "Answer in Claude ↗" : "Answer in terminal ↗")
                    Text("esc").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(NotchButtonStyle())
            .help("Let Claude Code show the question itself and open the session")
        }
    }
}

/// One selectable option: key number, radio / checkbox, bold label and muted description.
struct OptionRow: View {
    let number: Int
    let label: String
    let detail: String
    let multi: Bool
    let selected: Bool
    var muted = false
    let action: () -> Void

    var body: some View {
        HoverWrapper { hovering in
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(number <= 9 ? "\(number)" : "")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? Theme.amber : Theme.muted)
                        .frame(width: 18)
                    Image(systemName: glyph)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.amber : Theme.muted.opacity(0.8))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.system(size: 13, weight: muted ? .regular : .semibold))
                            .foregroundStyle(muted && !selected ? Theme.muted : .white)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: QuestionMetrics.descSize))
                                .foregroundStyle(Theme.muted)
                                .lineSpacing(1.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.vertical, QuestionMetrics.optionVPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Theme.waitingRow : hovering ? Theme.rowHover : Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Theme.amber.opacity(0.55) : Theme.cardBorder, lineWidth: 1))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .hapticHover()
    }

    private var glyph: String {
        if multi { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }
}

// MARK: - Plan drop-down

/// ExitPlanMode: session title, the plan as Markdown in a scroll view (reader typography),
/// Approve ⌘↩ (with ▾ modes) · Keep planning… (feedback -> deny with message) · Open session ↗.
struct PlanView: View {
    @ObservedObject var appState: AppState
    let request: PermissionRequest
    @EnvironmentObject private var ui: NotchUIState
    @Environment(\.notchStaticRender) private var staticRender

    private var feedbackOpen: Bool { ui.planFeedbackRequestId == request.id }

    var body: some View {
        let plan = request.plan
        VStack(alignment: .leading, spacing: 0) {
            NeedsYouStrip(appState: appState)
            NeedsYouTitle(title: sessionTitle(appState, request), verb: "has a plan for you to approve")
                .frame(height: PlanMetrics.titleRow, alignment: .top)
                .padding(.horizontal, ReaderMetrics.sidePad)
                .padding(.top, PlanMetrics.topPad)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, ReaderMetrics.sidePad) }
            ReaderScroll(staticRender: staticRender) {
                VStack(alignment: .leading, spacing: ReaderMetrics.blockSpacing) {
                    MarkdownBody(text: plan?.plan ?? "")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ReaderMetrics.sidePad)
                .padding(.top, ReaderMetrics.scrollTopPad + 4)
                .padding(.bottom, ReaderMetrics.scrollBottomPad)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, ReaderMetrics.sidePad) }

            VStack(alignment: .leading, spacing: PlanMetrics.feedbackGap) {
                if feedbackOpen {
                    HStack(spacing: 8) {
                        InlineTextField(placeholder: "What should change in the plan?",
                                        text: Binding(get: { ui.planFeedbackText }, set: { ui.planFeedbackText = $0 }),
                                        autoFocus: true) {
                            QuestionActions.sendPlanFeedback(appState: appState, ui: ui, request: request)
                        }
                        Button { QuestionActions.sendPlanFeedback(appState: appState, ui: ui, request: request) } label: {
                            Text("Send ↩")
                        }
                        .buttonStyle(NotchButtonStyle(background: Theme.accent, hPad: 12, vPad: 6, radius: 9))
                        .opacity(ui.planFeedbackText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.6 : 1)
                    }
                    .frame(height: PlanMetrics.feedback)
                }
                footer.frame(height: PlanMetrics.footer)
            }
            .padding(.horizontal, ReaderMetrics.sidePad)
            .padding(.top, PlanMetrics.footerGap)
            .padding(.bottom, PlanMetrics.bottomPad)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 1) {
                Button { QuestionActions.approvePlan(.manual, appState: appState, ui: ui, request: request) } label: {
                    HStack(spacing: 6) {
                        Text("Approve")
                        Text("⌘↩").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
                .buttonStyle(NotchButtonStyle(background: Color(hex: 0x1f6f3c)))
                .help("Approve the plan; Claude asks before each edit")
                ApproveModeMenu(staticRender: staticRender) { mode in
                    QuestionActions.approvePlan(mode, appState: appState, ui: ui, request: request)
                }
            }
            Button {
                if feedbackOpen {
                    ui.planFeedbackRequestId = nil
                    if ui.isEditing { ui.releaseKey() }
                } else {
                    ui.planFeedbackRequestId = request.id
                }
            } label: { Text(feedbackOpen ? "Cancel" : "Keep planning…") }
            .buttonStyle(NotchButtonStyle())
            .help("Tell Claude what to change; it stays in plan mode")
            Spacer(minLength: 8)
            Button { QuestionActions.answerInTerminal(appState: appState, ui: ui, request: request) } label: {
                Text("Open session ↗")
            }
            .buttonStyle(NotchButtonStyle())
            .help("Let Claude Code show the plan approval itself and open the session (esc)")
        }
    }
}

/// ▾ next to Approve: approve and switch permission mode (setMode, this session only).
struct ApproveModeMenu: View {
    let staticRender: Bool
    let action: (PlanApprovalMode) -> Void

    var body: some View {
        if staticRender {
            chevron
        } else {
            Menu {
                ForEach(PlanApprovalMode.allCases, id: \.self) { m in
                    Button(m.title) { action(m) }
                }
            } label: { chevron }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hapticHover()
            .help("Approve and choose how Claude continues (auto mode / auto-accept edits)")
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 33)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x1f6f3c)))
    }
}
