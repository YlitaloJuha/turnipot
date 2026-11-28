import SwiftUI
import NotchCore

/// Outline state of the island: body size (shoulders excluded) + bottom corner radius.
struct IslandShapeState: Equatable {
    var size: CGSize
    var radius: CGFloat
    /// Concave top-corner radius (0 while tucked into the notch, so the outline is exactly the notch).
    var shoulder: CGFloat = NotchGeometry.shoulderRadius
    /// Tucked into the physical notch (launch start / quit end).
    var hidden: Bool = false
    /// Right edge pulled in (one-sided idle pill, Presentation.rightTrim).
    var rightTrim: CGFloat = 0

    /// Tucked inside the physical notch: exactly notch-sized, no shoulders (invisible against it).
    static func hidden(_ g: NotchGeometry) -> IslandShapeState {
        IslandShapeState(size: g.hiddenBodySize, radius: NotchGeometry.collapsedBottomRadius, shoulder: 0, hidden: true)
    }

    func interpolated(to other: IslandShapeState, _ f: Double) -> IslandShapeState {
        let k = CGFloat(f)
        return IslandShapeState(
            size: CGSize(width: size.width + (other.size.width - size.width) * k,
                         height: size.height + (other.size.height - size.height) * k),
            radius: radius + (other.radius - radius) * k,
            shoulder: max(0, shoulder + (other.shoulder - shoulder) * k),
            rightTrim: rightTrim + (other.rightTrim - rightTrim) * k)
    }
}

/// All island timing in one place, shared by the live view, the window controller (launch /
/// quit sequencing) and the offscreen frame renderer.
enum IslandMotion {
    /// State changes that grow the island (expand, drop-downs): slight overshoot (~3%).
    static let growSpring = Spring(response: 0.42, dampingRatio: 0.74)
    /// Launch: springs out of the notch sideways, a touch bouncier (~5% overshoot).
    static let launchSpring = Spring(response: 0.5, dampingRatio: 0.68)
    /// Shrinking back to a smaller state: almost no bounce.
    static let shrinkSpring = Spring(response: 0.36, dampingRatio: 0.86)
    /// Retract into the notch (quit / screen change): critically damped, no bounce.
    static let retractSpring = Spring(response: 0.3, dampingRatio: 1.0)

    /// Content appears once the shape has mostly opened...
    static let contentInDelay: Double = 0.15
    static let contentInDuration: Double = 0.22
    /// ...and disappears before the shape starts to retract.
    static let contentOutDuration: Double = 0.08
    /// Shape retraction waits for the content fade-out.
    static let shrinkDelay: Double = 0.08
    /// Time the retract spring needs to settle visibly (used to sequence quit / screen change).
    static let retractDuration: Double = 0.38

    /// Mascot: the turnip rises out of its pot shortly after the pill has opened at launch,
    /// springy; sinks back quickly without bounce at quit. Quit waits `mascotPullUpDuration` for it before fading the content.
    static let mascotDropDelay: Double = 0.32
    static let mascotDropResponse: Double = 0.5
    static let mascotDropBounce: Double = 0.32
    static let mascotPullUpResponse: Double = 0.26
    static let mascotPullUpDuration: Double = 0.2
    static var mascotDropSpring: Spring { Spring(duration: mascotDropResponse, bounce: mascotDropBounce) }
    static var mascotPullUpSpring: Spring { Spring(duration: mascotPullUpResponse, bounce: 0) }

    static var contentIn: Animation { .easeOut(duration: contentInDuration) }
    static var contentOut: Animation { .easeIn(duration: contentOutDuration) }

    /// Animation for an outline change (nil = apply instantly: Reduce Motion).
    static func shapeAnimation(from old: IslandShapeState, to new: IslandShapeState, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        if old.hidden && !new.hidden { return .spring(launchSpring) }
        if new.hidden { return .spring(retractSpring) }
        return isShrink(from: old, to: new) ? .spring(shrinkSpring).delay(shrinkDelay) : .spring(growSpring)
    }

    static func isShrink(from old: IslandShapeState, to new: IslandShapeState) -> Bool {
        if abs(new.size.height - old.size.height) > 0.5 { return new.size.height < old.size.height }
        return new.size.width < old.size.width
    }

    /// Normalized progress (0 -> 1, may overshoot) of a spring started `delay` seconds after t = 0.
    static func progress(_ spring: Spring, t: Double, delay: Double = 0) -> Double {
        t <= delay ? 0 : spring.value(target: 1.0, time: t - delay)
    }

    /// Eased content fade-in progress (0...1) at time t.
    static func contentInProgress(t: Double) -> Double {
        let u = min(max((t - contentInDelay) / contentInDuration, 0), 1)
        return 1 - (1 - u) * (1 - u)       // ease-out
    }
}

/// Explicit animation frame for offscreen renders (`--render` writes anim/ frames): outline and
/// content values are given directly instead of being animated.
struct IslandFrameOverride {
    var shape: IslandShapeState
    var content: Presentation
    var contentOpacity: Double
    var contentScale: CGFloat = 1
    var contentOffset: CGFloat = 0
    /// Mascot extension (1 = hanging at rest, 0 = pulled up into the notch).
    var mascotExtension: Double = 1
    /// Seconds into the mascot's loop (Turnip's finished spring-out frames); nil = rest pose.
    var mascotTime: Double? = nil
    /// State-change frames (grow / shrink): the fade / scale applies to the per-state content only,
    /// like the live content transition (the shared wing mascot stays put). Launch / quit: false.
    var transitionOnly: Bool = false
}

/// Root view inside the fixed-size panel. A pure-black animatable NotchShape, top-centered and
/// flush with the screen's top edge. The outline is driven by `displayed` and animated with
/// springs on every change (grow: overshoot; shrink: waits for content fade-out first; launch /
/// quit: out of / back into the physical notch). Content is clipped to the animated outline and
/// cross-fades after the shape has mostly opened.
/// Hover / click-through is handled by NotchWindowController (the panel ignores mouse events
/// outside the island), so this view only handles clicks.
struct IslandView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var ui: NotchUIState
    var frameOverride: IslandFrameOverride? = nil

    /// Outline currently shown (animated towards the target computed in `body`).
    /// (LocalState instead of @State: the SwiftUI macro plugin is missing with CLT only.)
    @StateObject private var displayedBox = LocalState<IslandShapeState?>(nil)
    private var displayed: IslandShapeState? {
        get { displayedBox.value }
        nonmutating set { displayedBox.value = newValue }
    }

    static var spring: Animation { .spring(IslandMotion.growSpring) }

    /// Matches the outline's spring for in-place size changes (grow vs shrink), so content never
    /// moves on a different curve than the shape around it.
    private var sizeAnimation: Animation {
        guard let d = displayedBox.value else { return Self.spring }
        let p = Presentation.current(appState: appState, ui: ui)
        let target = IslandShapeState(size: p.bodySize(appState: appState, ui: ui), radius: p.bottomRadius,
                                      rightTrim: p.rightTrim(appState: appState))
        return IslandMotion.isShrink(from: d, to: target) ? .spring(IslandMotion.shrinkSpring) : Self.spring
    }

    var body: some View {
        let presentation = Presentation.current(appState: appState, ui: ui)
        let size = presentation.bodySize(appState: appState, ui: ui)
        let s = NotchGeometry.shoulderRadius
        let target = ui.islandShown
            ? IslandShapeState(size: size, radius: presentation.bottomRadius,
                               rightTrim: presentation.rightTrim(appState: appState))
            : IslandShapeState.hidden(ui.geometry)

        let o = frameOverride
        let shape = o?.shape ?? displayed ?? target
        let contentP = o?.content ?? presentation
        let contentSize = o == nil ? size : contentP.bodySize(appState: appState, ui: ui)
        let outline = NotchShape(bodyWidth: shape.size.width, bodyHeight: shape.size.height,
                                 shoulderRadius: shape.shoulder, bottomRadius: shape.radius,
                                 rightTrim: shape.rightTrim)
        let reduce = o == nil && ui.reduceMotion
        let split = o?.transitionOnly == true
        let opacity = split ? 1 : o?.contentOpacity ?? (ui.contentShown ? 1 : 0)
        let scale = split ? 1 : o?.contentScale ?? (ui.contentShown || reduce ? 1 : 0.92)

        ZStack(alignment: .top) {
            outline
                .fill(Color.black)
                .shadow(color: glow(for: contentP), radius: contentP.isCollapsed ? 0 : 11, y: 2)
                .animation(.easeInOut(duration: 0.25), value: contentP.isCollapsed)

            ZStack(alignment: .top) {
                // Each content view carries its OWN frame inside the id'd subtree, so an outgoing
                // view keeps its last size while it fades out. (Sizing the shared container to the
                // new state squeezed e.g. the expanded panel into the 32pt pill mid-fade and made
                // it reflow/jitter on hover-off.) Same-kind size changes (pill width when counts
                // change) follow the same springs as the outline so content and shape stay in sync.
                content(for: contentP)
                    .padding(.horizontal, s)
                    .frame(width: contentSize.width + 2 * s, height: contentSize.height, alignment: .top)
                    .animation(reduce ? nil : sizeAnimation, value: contentSize)
                    .scaleEffect(split ? o!.contentScale : 1, anchor: .top)
                    .offset(y: split ? o!.contentOffset : 0)
                    .opacity(split ? o!.contentOpacity : 1)
                    .id(contentP.kind)
                    .transition(contentTransition(reduceMotion: reduce))
                // The pill's mascot, shared by the pill, the expanded panel and the reader: drawn
                // outside the per-state content so it stays at exactly the same spot (and size)
                // when the pill expands, instead of fading out and back in elsewhere.
                wingMascot(for: contentP)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .scaleEffect(scale, anchor: .top)
            .offset(y: split ? 0 : o?.contentOffset ?? 0)
            .opacity(opacity)
            .environment(\.mascotExtension, o?.mascotExtension ?? (ui.mascotRetracted ? 0 : 1))
            .environment(\.mascotUsagePercent, appState.usage.weeklyPercent)
            .environment(\.mascotStripHeight, ui.geometry.notchHeight)
            .environment(\.mascotLoopTime, o?.mascotTime)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(outline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(outline)
        // Only the pill / near-limit banner react to a bare tap (a tap recognizer on the whole
        // island would compete with text selection in the reader).
        .gesture(TapGesture().onEnded { tapped(presentation) },
                 including: presentation.isCollapsed || presentation == .nearLimit || presentation == .usageReset ? .all : .subviews)
        .contextMenu { IslandMenuItems(appState: appState, ui: ui) }
        .opacity(ui.islandOpacity)
        .onAppear { if displayed == nil { displayed = target } }
        .onChange(of: target) { old, new in
            if let anim = IslandMotion.shapeAnimation(from: displayed ?? old, to: new, reduceMotion: ui.reduceMotion) {
                withAnimation(anim) { displayed = new }
            } else {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { displayed = new }
            }
        }
        .preferredColorScheme(.dark)
        .environmentObject(ui)
    }

    /// Presentations whose left wing carries the shared mascot.
    static func showsWingMascot(_ p: Presentation) -> Bool {
        switch p {
        case .collapsed, .expanded, .reader: return true
        default: return false
        }
    }

    /// Horizontal centre of the wing mascot relative to the notch centre: the pill's left wing
    /// starts `wing` left of the notch, and the mascot sits `PillLayout.leadingPad` into it.
    @MainActor
    static func wingMascotOffset(appState: AppState, ui: NotchUIState, for p: Presentation) -> CGFloat {
        let wing: CGFloat
        if case .collapsed(let w) = p { wing = w } else { wing = PillLayout.wing(appState: appState, ui: ui) }
        let mw = PillLayout.mascotWidth(strip: ui.geometry.notchHeight)
        return -(ui.geometry.notchRect.width / 2 + wing) + PillLayout.leadingPad + mw / 2
    }

    /// Left edge of the wing mascot measured from the left edge of a body `bodyWidth` wide (for
    /// laying out text beside it in the expanded panel / reader top bars).
    @MainActor
    static func wingMascotLeading(appState: AppState, ui: NotchUIState, bodyWidth: CGFloat) -> CGFloat {
        let mw = PillLayout.mascotWidth(strip: ui.geometry.notchHeight)
        return bodyWidth / 2 + wingMascotOffset(appState: appState, ui: ui, for: .expanded) - mw / 2
    }

    @ViewBuilder private func wingMascot(for p: Presentation) -> some View {
        let strip = ui.geometry.notchHeight
        let shown = Self.showsWingMascot(p)
        MascotView(mood: appState.mascotMood, pixelSize: MascotView.pixelSize(forStrip: strip), showZ: p.isCollapsed)
            .frame(width: PillLayout.mascotWidth(strip: strip), height: strip)
            .offset(x: Self.wingMascotOffset(appState: appState, ui: ui, for: p))
            .opacity(shown ? 1 : 0)
            .animation(.easeInOut(duration: shown ? 0.2 : 0.08), value: shown)
            .animation(.spring(IslandMotion.growSpring), value: Self.wingMascotOffset(appState: appState, ui: ui, for: p))
            .allowsHitTesting(false)
    }

    /// New content slides/scales down out of the notch after the shape has mostly opened; old
    /// content fades out quickly so the shape can retract without visible clipping.
    private func contentTransition(reduceMotion: Bool) -> AnyTransition {
        let removal = AnyTransition.opacity.animation(IslandMotion.contentOut)
        if reduceMotion {
            return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.05)), removal: removal)
        }
        let insertion = AnyTransition.opacity
            .combined(with: .scale(scale: 0.94, anchor: .top))
            .combined(with: .offset(y: -6))
            .animation(IslandMotion.contentIn.delay(IslandMotion.contentInDelay))
        return .asymmetric(insertion: insertion, removal: removal)
    }

    @ViewBuilder private func content(for p: Presentation) -> some View {
        switch p {
        case .collapsed(let wing):
            CollapsedView(appState: appState, geometry: ui.geometry, wing: wing)
        case .awaySummary:
            if let summary = appState.awaySummary {
                AwaySummaryView(appState: appState, summary: summary)
            }
        case .finished(let ids):
            let sessions = ids.compactMap { appState.session(id: $0) }
            if !sessions.isEmpty {
                FinishedView(appState: appState, sessions: sessions)
            }
        case .permission(let rid):
            if let r = appState.permission(id: rid) {
                switch r.kind {
                case .question where r.questions != nil: QuestionView(appState: appState, request: r)
                case .plan where r.plan != nil: PlanView(appState: appState, request: r)
                default: PermissionView(appState: appState, request: r)
                }
            }
        case .expanded:
            ExpandedView(appState: appState)
        case .nearLimit:
            if let w = appState.usage.nearLimitWindow {
                NearLimitView(appState: appState, window: w)
            }
        case .usageReset:
            if let r = appState.usageReset {
                UsageResetView(appState: appState, reset: r)
            }
        case .confirmation:
            if let c = ui.confirmation {
                ConfirmationView(confirmation: c, mood: appState.mascotMood)
            }
        case .reader(let sid):
            if let s = appState.session(id: sid) {
                ReaderView(appState: appState, session: s)
            }
        }
    }

    private func glow(for p: Presentation) -> Color {
        switch p {
        case .permission: return Theme.amber.opacity(0.35)
        case .collapsed: return .clear
        case .nearLimit: return Theme.red.opacity(0.25)
        case .usageReset: return Theme.green.opacity(0.22)
        default: return Color.black.opacity(0.5)
        }
    }

    /// Clicking the bare island: collapsed -> pin open; near-limit banner -> open the panel.
    private func tapped(_ p: Presentation) {
        switch p {
        case .collapsed, .nearLimit: appState.expand()
        case .usageReset: appState.dismissUsageReset(); appState.expand()
        default: break
        }
    }
}

/// Items of the island's right-click menu, also behind the ⚙ button in the panel / reader top bars.
struct IslandMenuItems: View {
    @ObservedObject var appState: AppState
    @ObservedObject var ui: NotchUIState
    @ObservedObject private var haptics = Haptics.shared
    @ObservedObject private var loginItem = LoginItem.shared
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        if let r = updates.available {
            Button("Update available: v\(r.version) — Download") { updates.openReleasePage() }
            Divider()
        }
        Button(appState.isPinnedExpanded ? "Unpin panel" : "Keep panel open") { appState.toggleExpanded() }
        Toggle("Trackpad haptics", isOn: Binding(get: { haptics.isEnabled }, set: { haptics.setEnabled($0) }))
        Toggle(loginItem.menuTitle, isOn: Binding(get: { loginItem.isOn }, set: { _ in loginItem.toggle(ui: ui) }))
        Toggle("Check for updates", isOn: Binding(get: { updates.isEnabled }, set: { updates.setEnabled($0) }))
        Divider()
        Button("Install Claude Code hook…") { SetupActions.installHook(appState: appState, ui: ui) }
        Button("Install editor extension…") { SetupActions.installExtension(appState: appState, ui: ui) }
        Divider()
        Button("Quit Turnipot") {
            // Via the run loop so the retract-then-quit sequence is never blocked by a
            // main-queue callout (see applicationShouldTerminate).
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
    }
}

/// ⚙ in the notch row: the right-click menu as a button (pin / ✕ styling).
struct SettingsMenuButton: View {
    @ObservedObject var appState: AppState
    @ObservedObject var ui: NotchUIState
    @StateObject private var hovering = LocalState(false)
    @Environment(\.notchStaticRender) private var staticRender

    var body: some View {
        if staticRender {
            // ImageRenderer can't draw NSMenu-backed buttons.
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 18, height: 20)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            IslandMenuItems(appState: appState, ui: ui)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering.value ? Color.white : Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 18, height: 20)
        .contentShape(Rectangle())
        .onHover { hovering.value = $0 }
        .help("Settings")
    }
}

/// Small icon button in the notch row (pin / ✕ styling: 10pt semibold, muted, white on hover).
struct BarIconButton: View {
    let systemName: String
    var active: Bool = false
    let help: String
    let action: () -> Void
    @StateObject private var hovering = LocalState(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : hovering.value ? Color.white : Theme.muted)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .help(help)
    }
}
