import SwiftUI
import AppKit
import NotchCore

/// Layout of the quick-reply field. One line: a 28pt text area beside the 28pt "Send ↩" button,
/// in a card with 6pt vertical padding (40pt); every extra line adds `lineHeight`, up to
/// `ReplyFieldGrowth.maxLines`, then the text scrolls inside. The containers (reader footer,
/// session row slot, finished drop-down) add `ui.replyFieldExtra[slot]` to their heights, so the
/// island grows together with the field.
enum ReplyFieldMetrics {
    static let fontSize: CGFloat = 13
    static var font: NSFont { NSFont.systemFont(ofSize: fontSize) }
    /// Height of one laid-out line of `font` (NSLayoutManager, as the NSTextView lays it out).
    static let lineHeight: CGFloat = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13))
    /// Text area of one line (= the Send button's height); the text is inset to centre in it.
    static let areaHeight: CGFloat = 28
    static var textInset: CGFloat { max(0, (areaHeight - lineHeight) / 2) }
    static let vPad: CGFloat = 6
    static let leadingPad: CGFloat = 12
    static let trailingPad: CGFloat = 6
    static let spacing: CGFloat = 8
    /// Fixed so the text area's width (and so its wrapping) is known without measuring views.
    static let sendWidth: CGFloat = 76
    /// NSTextContainer.lineFragmentPadding: keeps the caret off the area's edges.
    static let linePadding: CGFloat = 3
    /// One-line field height.
    static var oneLine: CGFloat { areaHeight + 2 * vPad }

    /// Width of the text area in a field `fieldWidth` wide (optionally with a "→ target" label).
    static func textWidth(fieldWidth: CGFloat, target: String? = nil) -> CGFloat {
        var w = fieldWidth - leadingPad - trailingPad - spacing - sendWidth
        if let target {
            let label = ("→ \(target)" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            w -= ceil(label) + spacing
        }
        return max(40, w)
    }

    /// Laid-out height of `text` in a text area `width` wide (same layout as the NSTextView).
    static func contentHeight(_ text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = linePadding
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var h = layout.usedRect(for: container).height
        if text.hasSuffix("\n") { h += lineHeight }   // the caret's empty last line
        return ceil(h)
    }

    static func extra(contentHeight: CGFloat) -> CGFloat {
        CGFloat(ReplyFieldGrowth.extraHeight(contentHeight: Double(contentHeight), lineHeight: Double(lineHeight)))
    }

    /// Offscreen renders: put a draft into `slot` with the height it would have.
    @MainActor
    static func setDraft(_ text: String, slot: String, fieldWidth: CGFloat, target: String? = nil, ui: NotchUIState) {
        ui.replyDrafts[slot] = text
        ui.replyFieldExtra[slot] = extra(contentHeight: contentHeight(text, width: textWidth(fieldWidth: fieldWidth, target: target)))
    }
}

/// Quick-reply row (mockup `.reply`): optional "→ target" label, a wrapping multi-line text area
/// (1 to 5 lines, then it scrolls) and the orange "Send ↩" button beside it (never over the text).
/// Return sends, ⇧↩ / ⌥↩ insert a new line. The draft and its height live in NotchUIState under
/// `slot` ("reader-<id>", "row-<id>", "finished-<id>"), so the containers can size themselves.
///
/// The notch panel is non-activating and normally refuses key status so it never steals typing
/// from the frontmost app. Clicking the text view (NotchPanel.sendEvent detects NSText views) or
/// this view's tap gesture asks the controller to make the panel key; focus then moves into it.
struct ReplyField: View {
    let slot: String
    var placeholder: String = "Reply…"
    var target: String? = nil
    var autoFocus: Bool = false
    /// Non-nil: the field is disabled (text area, Send) and shows this as placeholder and tooltip.
    var disabledReason: String? = nil
    let onSend: (String) -> Void

    @EnvironmentObject private var ui: NotchUIState
    @StateObject private var focused = LocalState(false)
    /// Bumped to move keyboard focus into the text view.
    @StateObject private var focusToken = LocalState(0)
    /// The text as typed (re-renders only this field; mirrored into ui.replyDrafts).
    @StateObject private var draft = LocalState<String?>(nil)
    @Environment(\.notchStaticRender) private var staticRender

    static let help = "Return sends · ⇧Return or ⌥Return adds a line (lines are sent joined by spaces)"
    /// Tooltip / placeholder while Claude may be showing a dialog in the session's terminal.
    static let terminalDialogHelp = "Claude is showing a prompt in the terminal — answer it there"
    /// The same, short enough for the field (the full text is its tooltip).
    static let terminalDialogShort = "Prompt open in the terminal — answer it there"

    /// `disabledReason` for a session (nil = quick reply available).
    @MainActor
    static func disabledReason(appState: AppState, sessionId: String) -> String? {
        appState.terminalDialogMayBeOpen(sessionId) ? terminalDialogHelp : nil
    }

    private var text: String { draft.value ?? ui.replyDrafts[slot] ?? "" }

    var body: some View {
        if let disabledReason {
            disabledBody(disabledReason)
        } else {
            enabledBody
        }
    }

    /// Same card, no text view: the reason as a muted placeholder and a dimmed, disabled Send.
    private func disabledBody(_ reason: String) -> some View {
        HStack(alignment: .center, spacing: ReplyFieldMetrics.spacing) {
            if let target {
                Text("→ \(target)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(reason == Self.terminalDialogHelp ? Self.terminalDialogShort : reason)
                .font(.system(size: 12))
                .foregroundStyle(Theme.amber.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, ReplyFieldMetrics.linePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {} label: { Text("Send ↩").fixedSize() }
                .buttonStyle(NotchButtonStyle(background: Theme.accent, hPad: 12, vPad: 6, radius: 9))
                .frame(width: ReplyFieldMetrics.sendWidth, height: ReplyFieldMetrics.areaHeight)
                .disabled(true)
                .opacity(0.35)
        }
        .frame(height: ReplyFieldMetrics.areaHeight)
        .padding(.leading, ReplyFieldMetrics.leadingPad)
        .padding(.trailing, ReplyFieldMetrics.trailingPad)
        .padding(.vertical, ReplyFieldMetrics.vPad)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.amber.opacity(0.35), lineWidth: 1))
        )
        .help(reason)
    }

    private var enabledBody: some View {
        let extra = ui.replyFieldExtra[slot] ?? 0
        return HStack(alignment: .bottom, spacing: ReplyFieldMetrics.spacing) {
            if let target {
                Text("→ \(target)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: ReplyFieldMetrics.areaHeight)
            }
            textArea
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: ReplyFieldMetrics.areaHeight + extra)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: ReplyFieldMetrics.fontSize))
                            .foregroundStyle(Theme.muted.opacity(0.7))
                            .lineLimit(1)
                            .padding(.leading, ReplyFieldMetrics.linePadding)
                            .padding(.top, ReplyFieldMetrics.textInset)
                            .allowsHitTesting(false)
                    }
                }
            Button(action: submit) {
                Text("Send ↩").fixedSize()
            }
            .buttonStyle(NotchButtonStyle(background: Theme.accent, hPad: 12, vPad: 6, radius: 9))
            .frame(width: ReplyFieldMetrics.sendWidth, height: ReplyFieldMetrics.areaHeight)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 1)
        }
        .padding(.leading, ReplyFieldMetrics.leadingPad)
        .padding(.trailing, ReplyFieldMetrics.trailingPad)
        .padding(.vertical, ReplyFieldMetrics.vPad)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(focused.value ? Theme.accent.opacity(0.6) : Theme.cardBorder, lineWidth: 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { beginEditing() }
        .help(Self.help)
        .onAppear {
            if autoFocus { beginEditing() }
        }
    }

    @ViewBuilder private var textArea: some View {
        if staticRender {
            // Offscreen renders: ImageRenderer can't draw the NSTextView.
            Text(text)
                .font(.system(size: ReplyFieldMetrics.fontSize))
                .foregroundStyle(.white)
                .lineLimit(ReplyFieldGrowth.maxLines)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, ReplyFieldMetrics.linePadding)
                .padding(.top, ReplyFieldMetrics.textInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ReplyTextView(text: text, focusToken: focusToken.value,
                          onChange: { t, contentHeight in setText(t, contentHeight: contentHeight) },
                          onSubmit: submit,
                          onFocus: { f in
                              focused.value = f
                              ui.isEditing = f
                          })
        }
    }

    private func setText(_ t: String, contentHeight: CGFloat) {
        if draft.value != t { draft.value = t }
        ui.replyDrafts[slot] = t
        let extra = ReplyFieldMetrics.extra(contentHeight: contentHeight)
        if (ui.replyFieldExtra[slot] ?? 0) != extra {
            // The field and the island around it grow on the island's spring.
            withAnimation(.spring(IslandMotion.growSpring)) { ui.replyFieldExtra[slot] = extra }
        }
    }

    private func beginEditing() {
        ui.requestKey()
        DispatchQueue.main.async { focusToken.value += 1 }
    }

    private func submit() {
        guard disabledReason == nil else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft.value = ""
        ui.replyDrafts[slot] = nil
        // Like the old single-line field: sending ends editing (←/→ page the reader again).
        if let w = NSApp.keyWindow, w.firstResponder is ReplyNSTextView { w.makeFirstResponder(nil) }
        withAnimation(.spring(IslandMotion.shrinkSpring)) { ui.replyFieldExtra[slot] = nil }
        onSend(t)
    }
}

/// The NSTextView behind ReplyField: wraps, scrolls inside once it is taller than the field,
/// Return submits (⇧/⌥/⌃ + Return insert a new line), ⌘C / ⌘V / ⌘A / ⌘X / ⌘Z arrive through
/// NotchWindowController's key monitor (NSApp.sendAction to the first responder).
struct ReplyTextView: NSViewRepresentable {
    let text: String
    let focusToken: Int
    let onChange: (String, CGFloat) -> Void
    let onSubmit: () -> Void
    let onFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ReplyScrollView {
        let scroll = ReplyScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none

        let tv = ReplyNSTextView()
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = ReplyFieldMetrics.font
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.drawsBackground = false
        tv.typingAttributes = [.font: ReplyFieldMetrics.font, .foregroundColor: NSColor.white]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: ReplyFieldMetrics.textInset)
        tv.textContainer?.lineFragmentPadding = ReplyFieldMetrics.linePadding
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.string = text
        tv.delegate = context.coordinator
        tv.onFocus = { [weak coordinator = context.coordinator] f in coordinator?.parent.onFocus(f) }
        scroll.documentView = tv
        scroll.onResize = { [weak coordinator = context.coordinator] in coordinator?.widthChanged() }
        context.coordinator.textView = tv
        context.coordinator.lastFocusToken = focusToken
        return scroll
    }

    func updateNSView(_ scroll: ReplyScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text {
            tv.string = text          // cleared after sending / draft restored
            DispatchQueue.main.async { c.report() }
        }
        if focusToken != c.lastFocusToken {
            c.lastFocusToken = focusToken
            DispatchQueue.main.async {
                if let w = tv.window, w.firstResponder !== tv { w.makeFirstResponder(tv) }
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReplyTextView
        weak var textView: ReplyNSTextView?
        var lastFocusToken = 0
        private var lastWidth: CGFloat = 0

        init(_ parent: ReplyTextView) { self.parent = parent }

        /// Laid-out text height (empty trailing line included).
        func contentHeight() -> CGFloat {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return ReplyFieldMetrics.lineHeight }
            lm.ensureLayout(for: tc)
            var h = lm.usedRect(for: tc).height
            if lm.extraLineFragmentTextContainer == tc { h = max(h, lm.extraLineFragmentRect.maxY) }
            return ceil(max(h, ReplyFieldMetrics.lineHeight))
        }

        func report() {
            guard let tv = textView else { return }
            parent.onChange(tv.string, contentHeight())
            tv.scrollRangeToVisible(tv.selectedRange())
        }

        func widthChanged() {
            guard let tv = textView, abs(tv.frame.width - lastWidth) > 0.5 else { return }
            lastWidth = tv.frame.width
            // Called from AppKit layout (possibly inside a SwiftUI update): report afterwards.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func textDidChange(_ notification: Notification) { report() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let flags = ((textView as? ReplyNSTextView)?.keyFlags ?? NSApp.currentEvent?.modifierFlags ?? [])
                    .intersection(.deviceIndependentFlagsMask)
                switch ReplyFieldGrowth.returnAction(shift: flags.contains(.shift), option: flags.contains(.option),
                                                     control: flags.contains(.control)) {
                case .send: parent.onSubmit()
                case .newline: textView.insertText("\n", replacementRange: textView.selectedRange())
                }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                return true   // no tabs in a reply; don't move focus around the panel either
            default:
                return false
            }
        }
    }
}

/// The reply field's scroll view (the reader's scroll handling skips gestures over it).
final class ReplyScrollView: NSScrollView {
    var onResize: (() -> Void)?
    override func tile() {
        super.tile()
        // The text view fills at least the visible area (clicks below the text still land in it).
        if let tv = documentView as? NSTextView, abs(tv.minSize.height - contentSize.height) > 0.5 {
            tv.minSize = NSSize(width: 0, height: contentSize.height)
        }
        onResize?()
    }
}

final class ReplyNSTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    /// Modifiers of the key event being handled (decides ↩ = send vs ⇧↩ / ⌥↩ = new line).
    private(set) var keyFlags: NSEvent.ModifierFlags?
    override func keyDown(with event: NSEvent) {
        keyFlags = event.modifierFlags
        defer { keyFlags = nil }
        super.keyDown(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
    /// Removed while focused (e.g. the row's ↩ toggled off): AppKit doesn't always call
    /// resignFirstResponder then, so report the focus loss (else ui.isEditing stays true).
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let w = window, w.firstResponder === self {
            let onFocus = onFocus
            DispatchQueue.main.async { onFocus?(false) }
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Replaces ReplyField for Claude Desktop sessions: nothing can type into Claude Desktop, so this
/// is a full-width card with a "Reply in Claude ↗" button that activates Claude Desktop (via
/// AppState.focusSession, which also marks the session seen).
struct DesktopReplyButton: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Say why there's no field: quick reply types into terminals; Claude Desktop has no
            // way to receive text from another app.
            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                // Shorter wording where the slot is narrow (the panel's inline ↩ slot).
                ViewThatFits(in: .horizontal) {
                    Text("Quick reply works in terminal sessions only")
                    Text("Quick reply: terminals only")
                    Text("Terminals only")
                }
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Turnipot can type replies into Terminal, iTerm2 and editor terminals, but Claude Desktop doesn't accept text from other apps. Reply there instead.")
            DesktopReplyChip(action: action)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1))
        )
    }
}

/// The orange "Reply in Claude ↗" button itself.
struct DesktopReplyChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Reply in Claude ↗").fixedSize()
        }
        .buttonStyle(NotchButtonStyle(background: Theme.accent, hPad: 12, vPad: 6, radius: 9))
        .help("Show in Claude Desktop to reply there (quick reply can't type into Claude Desktop)")
    }
}
