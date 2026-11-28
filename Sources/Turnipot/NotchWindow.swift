import AppKit
import Combine
import SwiftUI
import NotchCore

/// Borderless, transparent, non-activating panel above the menu bar covering the notch area.
/// It refuses key status (so clicking it never steals typing from the frontmost app) unless
/// `allowsKey` is set — which happens only when the user clicks into a reply text field.
final class NotchPanel: NSPanel {
    var allowsKey = false
    /// Called when a mouse-down lands on a text input while the panel isn't key.
    var onTextFieldMouseDown: (() -> Void)?

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)   // above the menu bar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow, let content = contentView {
            let p = content.convert(event.locationInWindow, from: nil)
            var v = content.hitTest(p)
            while let view = v {
                if view is NSText || view is NSTextField || view is ReplyScrollView { onTextFieldMouseDown?(); break }
                v = view.superview
            }
        }
        super.sendEvent(event)
    }

    // Never let the panel be pushed below the menu bar / constrained by AppKit.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that accepts the first click (no "activate first" click for the inactive app).
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel, hosts IslandView, keeps it positioned on screen changes, and makes clicks
/// outside the visible island pass through (ignoresMouseEvents toggled by hit-testing the
/// current island rect from global/local mouse monitors). Also drives hover-expand.
@MainActor
final class NotchWindowController {
    let appState: AppState
    let ui: NotchUIState
    private(set) var panel: NotchPanel?
    var geometry: NotchGeometry { ui.geometry }

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var mouseInside = false
    private var hoverTask: Task<Void, Never>?
    /// Polls the pointer while it is over the island: a non-key panel doesn't reliably receive
    /// mouseMoved events, and global monitors only see events destined for other apps.
    private var insidePoll: Timer?
    private let hotKeys = PermissionHotKeys()
    private var hotKeyGate = HotKeyGate()
    private var replyLoader: ReplyLoader?
    /// Scroll-to-read gesture tracking (see handleScroll; the reader uses `backGesture`).
    private var scrollAccum: CGFloat = 0
    private var scrollGestureAllowed = false
    private var scrollGestureDone = false
    private var lastScrollEventAt = Date.distantPast

    static let hoverInDelay: TimeInterval = 0.15
    static let hoverOutDelay: TimeInterval = 0.3
    /// Clicks elsewhere within this long after the away summary appears don't dismiss it.
    static let awayClickGrace: TimeInterval = 1.5

    init(appState: AppState) {
        self.appState = appState
        self.ui = NotchUIState(geometry: NotchGeometry.current())
    }

    func show() {
        // Start tucked inside the physical notch; appear() springs it out once the panel is on screen.
        ui.islandShown = false
        ui.contentShown = false
        ui.mascotRetracted = true
        let panel = NotchPanel(contentRect: geometry.panelFrame)
        let host = NotchHostingView(rootView: IslandView(appState: appState, ui: ui))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: geometry.panelFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.ignoresMouseEvents = true
        panel.onTextFieldMouseDown = { [weak self] in self?.requestKey() }
        panel.setFrame(geometry.panelFrame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        ui.requestKeyHandler = { [weak self] in self?.requestKey() }
        ui.releaseKeyHandler = { [weak self] in self?.releaseKey() }

        hotKeys.onAction = { [weak self] action in self?.handleHotKey(action) }
        replyLoader = ReplyLoader(appState: appState, ui: ui)
        appState.$readerSessionId
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] id in MainActor.assumeIsolated { self?.readerChanged(id) } }
            .store(in: &cancellables)

        installObservers()
        installMouseMonitors()
        updateMouseState()
        updateHotKeys()
        // Give the hidden first frame a moment to reach the screen, then launch-animate.
        let gen = animationGeneration
        after(0.12) { [weak self] in
            guard let self, self.animationGeneration == gen else { return }
            self.appear()
        }
    }

    // MARK: Launch / retract animation

    /// Bumped by every appear()/retract() so stale scheduled steps of an interrupted sequence
    /// (e.g. a screen change during the launch animation) do nothing.
    private var animationGeneration = 0
    private(set) var isRetracting = false

    /// Delayed step on a common-modes run loop timer, so it also fires in the modal run loop
    /// used while termination is pending, even if terminate was called from a main-queue block.
    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Self.runLoopAfter(seconds, work)
    }

    static func runLoopAfter(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { work() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Launch animation: the notch-sized black shape springs out sideways to the collapsed pill,
    /// then (once mostly open) the content fades/scales in and the mascot drops down out of the
    /// notch. Reduce Motion: the island simply fades in at its final size.
    func appear() {
        animationGeneration += 1
        let gen = animationGeneration
        isRetracting = false
        if ui.reduceMotion {
            ui.islandOpacity = 0
            ui.islandShown = true
            ui.contentShown = true
            ui.mascotRetracted = false
            withAnimation(.easeOut(duration: 0.25)) { ui.islandOpacity = 1 }
        } else {
            ui.islandOpacity = 1
            ui.islandShown = true          // IslandView springs the outline out of the notch
            after(IslandMotion.contentInDelay) { [weak self] in
                guard let self, self.animationGeneration == gen else { return }
                withAnimation(IslandMotion.contentIn) { self.ui.contentShown = true }
            }
            ui.mascotRetracted = true
            after(IslandMotion.mascotDropDelay) { [weak self] in
                guard let self, self.animationGeneration == gen else { return }
                self.ui.mascotRetracted = false   // the turnip rises out of its pot
            }
        }
        updateMouseState()
    }

    /// Reverse of appear(): the mascot pulls up into the notch, the content fades out, then the
    /// shape retracts into the notch.
    /// `completion` runs once the island is visually gone (used before quitting / moving screens).
    func retract(completion: @escaping @MainActor () -> Void) {
        animationGeneration += 1
        let gen = animationGeneration
        isRetracting = true
        hoverTask?.cancel()
        updateMouseState()
        guard panel != nil, ui.islandShown else { completion(); return }
        if ui.reduceMotion {
            withAnimation(.easeIn(duration: 0.18)) { ui.islandOpacity = 0 }
            after(0.2) { [weak self] in
                guard let self, self.animationGeneration == gen else { return }
                self.ui.contentShown = false
                self.ui.islandShown = false
                self.ui.mascotRetracted = true
                completion()
            }
            return
        }
        let pullUp = ui.mascotRetracted ? 0 : IslandMotion.mascotPullUpDuration
        ui.mascotRetracted = true          // the turnip sinks into its pot first
        after(pullUp) { [weak self] in
            guard let self, self.animationGeneration == gen else { return }
            withAnimation(IslandMotion.contentOut) { self.ui.contentShown = false }
            self.after(IslandMotion.contentOutDuration) { [weak self] in
                guard let self, self.animationGeneration == gen else { return }
                self.ui.islandShown = false    // IslandView retracts the outline into the notch
                self.after(IslandMotion.retractDuration) { [weak self] in
                    guard let self, self.animationGeneration == gen else { return }
                    completion()
                }
            }
        }
    }

    /// Recompute geometry and move the panel (screen change, display (dis)connect). The panel
    /// frame itself never animates: when the notch moves, the island first retracts into the old
    /// notch, the (fixed-size, transparent) panel jumps while empty, and the island re-launches
    /// out of the new one.
    func reposition() {
        let g = NotchGeometry.current()
        guard g != ui.geometry else {
            if !isRetracting {
                panel?.setFrame(g.panelFrame, display: true)
                panel?.orderFrontRegardless()
            }
            updateMouseState()
            return
        }
        retract { [weak self] in
            guard let self else { return }
            let latest = NotchGeometry.current()
            self.ui.geometry = latest
            self.panel?.setFrame(latest.panelFrame, display: true)
            self.panel?.orderFrontRegardless()
            // Let the hidden frame land on the new screen before springing out.
            let gen = self.animationGeneration
            self.after(0.05) { [weak self] in
                guard let self, self.animationGeneration == gen else { return }
                self.appear()
            }
        }
    }

    // MARK: Observers

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }
        // Island size changes with state: re-evaluate pass-through/hover and hot keys afterwards.
        appState.objectWillChange
            .merge(with: ui.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateMouseState()
                    self?.updateHotKeys()
                    self?.updateHaptics()
                }
            }
            .store(in: &cancellables)
    }

    private func installMouseMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updateMouseState(); self?.pointerMoved(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.updateMouseState(); self?.pointerMoved(e) }
            return e
        }) { monitors.append(m) }
        // Click anywhere outside our panel: end editing, unpin.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(m) }
        // Keys while the panel is key (editing a reply / reader open): esc closes, ←/→ page the
        // reader, ⌘C / ⌘A / ⌘V / ⌘X / ⌘Z go to the focused view (there is no Edit menu in an
        // LSUIElement app, so the key equivalents are routed here).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            let handled = MainActor.assumeIsolated { () -> Bool in
                self?.handleKeyDown(e) ?? false
            }
            return handled ? nil : e
        }) { monitors.append(m) }
        // Scroll-to-read (expanded panel rows, finished drop-down, away summary) and
        // overscroll-at-top back to the list (reader).
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            let handled = MainActor.assumeIsolated { () -> Bool in
                self?.handleScroll(e) ?? false
            }
            return handled ? nil : e
        }) { monitors.append(m) }
    }

    // MARK: Keys

    private func handleKeyDown(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Question / plan drop-down with a text field focused ("Other…" / plan feedback):
        // ⌘↩ submits, esc just stops editing (never throws the typed text away).
        if case .permission(let id) = currentPresentation, let req = appState.permission(id: id), req.kind != .permission {
            if e.keyCode == 53 {
                ui.releaseKey()
                return true
            }
            if flags == .command && (e.keyCode == 36 || e.keyCode == 76) {
                if req.kind == .question { QuestionActions.primary(appState: appState, ui: ui, request: req) }
                else if ui.planFeedbackRequestId == req.id { QuestionActions.sendPlanFeedback(appState: appState, ui: ui, request: req) }
                else { QuestionActions.approvePlan(.manual, appState: appState, ui: ui, request: req) }
                return true
            }
        }
        if e.keyCode == 53 {   // esc
            if appState.readerSessionId != nil {
                ui.resetInteraction()
                releaseKey()
                appState.closeReader()
                return true
            }
            if appState.awaySummary != nil { appState.dismissAwaySummary() }
            ui.resetInteraction()
            appState.collapse()
            return true
        }
        if flags == .command, let chars = e.charactersIgnoringModifiers?.lowercased() {
            let selector: Selector?
            switch chars {
            case "c": selector = #selector(NSText.copy(_:))
            case "a": selector = #selector(NSResponder.selectAll(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "x": selector = #selector(NSText.cut(_:))
            case "z": selector = Selector(("undo:"))
            default: selector = nil
            }
            if let selector { return NSApp.sendAction(selector, to: nil, from: panel) }
            return false
        }
        // ←/→ page the reader unless a text field is being edited.
        if let sid = appState.readerSessionId, !ui.isEditing, flags.isDisjoint(with: [.command, .option, .control]) {
            let busy = appState.session(id: sid)?.status == .busy
            switch e.keyCode {
            case 123: withAnimation(.spring(IslandMotion.growSpring)) { ui.readerStep(-1, busy: busy) }; return true
            case 124: withAnimation(.spring(IslandMotion.growSpring)) { ui.readerStep(1, busy: busy) }; return true
            default: break
            }
        }
        return false
    }

    // MARK: Scroll to read

    /// Minimum scroll distance (points) of one gesture before it opens the reader.
    static let readScrollThreshold: CGFloat = 24
    /// Upward overscroll at the top of the reply (points) before it goes back to the list.
    static let backScrollThreshold: Double = 60

    /// Rules:
    /// - Expanded panel: scrolling never opens anything; it only scrolls the session list
    ///   (click ≡ on a row to read its reply).
    /// - Finished drop-down (message / "Read ⌄") and away summary rows: scrolling down opens it.
    /// - Reader: see handleReaderScroll (OverscrollBackGesture).
    /// Momentum (inertial) events never trigger anything; gestures that start over a reply
    /// field (it scrolls itself once it holds more than 5 lines) neither. Returns true to
    /// swallow the event.
    private func handleScroll(_ e: NSEvent) -> Bool {
        guard mouseInside, !isRetracting else { setBackProgress(0); return false }
        let now = Date()
        // Gesture boundaries: trackpads report phases; mouse wheels don't (0.35 s gap = new gesture).
        let isWheel = e.phase.isEmpty && e.momentumPhase.isEmpty
        let isNewGesture = e.phase == .began || e.phase == .mayBegin
            || (isWheel && now.timeIntervalSince(lastScrollEventAt) > 0.35)
        lastScrollEventAt = now
        if isNewGesture { scrollGestureOverReplyField = pointerIsOverReplyField() }
        let p = currentPresentation
        if case .reader = p { return handleReaderScroll(e, isNewGesture: isNewGesture) }
        backGesture.reset()
        if case .expanded = p { noteListPosition(refresh: isNewGesture) }
        if isNewGesture {
            scrollAccum = 0
            scrollGestureDone = false
            scrollGestureAllowed = !scrollGestureOverReplyField && scrollGestureCanTrigger(p)
            gestureReadTarget = ui.readTarget
        }
        guard e.momentumPhase.isEmpty, !scrollGestureDone, scrollGestureAllowed else { return false }
        // A target that slid under the pointer mid-gesture never opens.
        guard ui.readTarget == gestureReadTarget else { return false }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        scrollAccum += dy
        switch p {
        case .finished, .awaySummary:
            guard let target = ui.readTarget, appState.session(id: target.sessionId) != nil else { return false }
            guard scrollAccum <= -Self.readScrollThreshold else { return false }
            scrollGestureDone = true
            ui.stickyFinishedIds = nil
            ui.replyTargetId = nil
            appState.openReader(sessionId: target.sessionId)
            return true
        default:
            return false
        }
    }

    /// Reader: an upward gesture that STARTS with the reply at its top and keeps pulling up past
    /// it (`backScrollThreshold`, while still at the top) goes back to the list; "‹ Sessions"
    /// fades in at the top meanwhile. Whether the reply is at its top is read from its
    /// NSScrollView's clip view before the event is applied (this monitor runs first), so a
    /// gesture that scrolled the reply up never counts, even once it reaches the top.
    private func handleReaderScroll(_ e: NSEvent, isNewGesture: Bool) -> Bool {
        let phase: ScrollGesturePhase
        if !e.momentumPhase.isEmpty { phase = .momentum }
        else if isNewGesture { phase = .began }
        else if e.phase == .ended || e.phase == .cancelled { phase = .ended }
        else { phase = .changed }
        if scrollGestureOverReplyField {
            backGesture.reset()
            setBackProgress(0)
            return false
        }
        // No scroll view found (shouldn't happen): never go back on a guess.
        // Looked up once per gesture (walking the panel's view tree on every event is costly).
        if isNewGesture || gestureScrollView?.window == nil { gestureScrollView = readerScrollView() }
        let atTop = gestureScrollView.map { ScrollPosition.isAtTop(distanceFromTop: Self.distanceFromTop($0)) } ?? false
        let dy = Double(e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8)
        switch backGesture.handle(phase, deltaUp: dy, atTop: atTop) {
        case .none:
            setBackProgress(0)
            return false
        case .progress(let f):
            setBackProgress(f)
            return false          // the scroll view still rubber-bands
        case .back:
            setBackProgress(0)
            // The rest of this gesture lands on the list: it must not open a reader there.
            scrollGestureDone = true
            scrollGestureAllowed = false
            releaseKey()
            appState.readerBack()
            return true
        }
    }

    private var backGesture = OverscrollBackGesture(threshold: NotchWindowController.backScrollThreshold)
    /// The current gesture started over a reply field (its own scroll view): ignore it.
    private var scrollGestureOverReplyField = false
    /// The reader's scroll view for the current gesture (see handleReaderScroll).
    private weak var gestureScrollView: NSScrollView?

    private func setBackProgress(_ f: Double) {
        let q = (f * 20).rounded() / 20      // 5% steps: fewer re-renders while pulling
        guard ui.readerBackProgress != q else { return }
        withAnimation(.easeOut(duration: q == 0 ? 0.2 : 0.08)) { ui.readerBackProgress = q }
    }

    /// Read target under the pointer when the gesture began.
    private var gestureReadTarget: NotchUIState.ReadTarget?
    private weak var listScrollView: NSScrollView?
    private var lastListOriginY: CGFloat?

    /// Called on every scroll event while the list shows (before the event is applied): if the
    /// list's offset changed since the previous event, it scrolled under the pointer (parks
    /// hover-to-reveal until the pointer moves).
    private func noteListPosition(refresh: Bool) {
        if refresh || listScrollView?.window == nil {
            let found = mainScrollView()
            if found !== listScrollView { lastListOriginY = nil }    // panel reopened / view rebuilt
            listScrollView = found
        }
        guard let s = listScrollView else { return }
        let y = s.contentView.bounds.origin.y
        if let last = lastListOriginY, abs(y - last) > 0.5 {
            ui.rowListScrolled()
        }
        lastListOriginY = y
    }

    /// Pointer movement resumes hover-to-reveal after a scroll.
    private func pointerMoved(_ e: NSEvent) { ui.pointerMoved() }

    private func scrollGestureCanTrigger(_ p: Presentation) -> Bool {
        switch p {
        case .finished, .awaySummary:
            return true
        default:
            return false     // the session list only ever scrolls (≡ / click opens the reader)
        }
    }

    // MARK: Scroll views in the panel

    /// Every NSScrollView in the panel (SwiftUI's ScrollView is an NSScrollView on macOS).
    private func scrollViews() -> [NSScrollView] {
        guard let root = panel?.contentView else { return [] }
        var out: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, !s.isHiddenOrHasHiddenAncestor { out.append(s) }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return out
    }

    private func pointerWindowRect(_ v: NSView) -> CGRect { v.convert(v.bounds, to: nil) }

    private func pointerIsOverReplyField() -> Bool {
        guard let panel else { return false }
        let p = panel.mouseLocationOutsideOfEventStream
        return scrollViews().contains { $0 is ReplyScrollView && pointerWindowRect($0).contains(p) }
    }

    /// The island's main scroll view (reader reply / session list; reply fields excluded): the
    /// one under the pointer, else the tallest.
    private func mainScrollView() -> NSScrollView? {
        guard let panel else { return nil }
        let candidates = scrollViews().filter { !($0 is ReplyScrollView) && $0.documentView != nil }
        let p = panel.mouseLocationOutsideOfEventStream
        if let hit = candidates.filter({ pointerWindowRect($0).contains(p) }).max(by: { $0.frame.height < $1.frame.height }) {
            return hit
        }
        return candidates.max { $0.frame.height < $1.frame.height }
    }

    private func readerScrollView() -> NSScrollView? { mainScrollView() }

    static func distanceFromTop(_ s: NSScrollView) -> Double {
        let clip = s.contentView
        return ScrollPosition.distanceFromTop(originY: clip.bounds.origin.y, visibleHeight: clip.bounds.height,
                                              documentHeight: Double(s.documentView?.frame.height ?? 0),
                                              flipped: s.documentView?.isFlipped ?? clip.isFlipped,
                                              topInset: s.contentInsets.top)
    }

    static func distanceFromBottom(_ s: NSScrollView) -> Double {
        let clip = s.contentView
        return ScrollPosition.distanceFromBottom(originY: clip.bounds.origin.y, visibleHeight: clip.bounds.height,
                                                 documentHeight: Double(s.documentView?.frame.height ?? 0),
                                                 flipped: s.documentView?.isFlipped ?? clip.isFlipped,
                                                 bottomInset: s.contentInsets.bottom)
    }

    // MARK: Reader key status

    /// The reader takes key status while the pointer is over it (text selection / ⌘C, ←/→, esc)
    /// and gives it back when the pointer leaves (unless a reply is being typed), so it never
    /// holds on to typing meant for the terminal while you work elsewhere. Closing releases it.
    private func readerChanged(_ id: String?) {
        if id != nil {
            if mouseInside { requestKey() }
        } else if panel?.isKeyWindow == true && !ui.isEditing {
            releaseKey()
        }
    }

    // MARK: Mouse / hover

    private var currentPresentation: Presentation { Presentation.current(appState: appState, ui: ui) }

    /// Island rect in screen coordinates for the current presentation (slightly padded; extends
    /// above the screen edge so the top pixel row counts as inside).
    private var islandScreenRect: CGRect {
        // Tucked away / retracting: nothing to hover or click.
        guard ui.islandShown, !isRetracting else { return .null }
        let size = currentPresentation.bodySize(appState: appState, ui: ui)
        var r = geometry.islandScreenRect(bodySize: size, rightTrim: currentPresentation.rightTrim(appState: appState))
        r.size.height += 4
        return r.insetBy(dx: -2, dy: -2)
    }

    private func updateMouseState() {
        guard let panel else { return }
        let p = NSEvent.mouseLocation
        let inside = islandScreenRect.contains(p)
        let ignore = !inside && !ui.isEditing
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
        // A drop-down that appeared under the pointer arms its hot keys once the pointer moves.
        if inside && mouseInside && !hotKeyGate.isArmed { updateHotKeys() }
        // Close (✕) guard: cleared once the pointer is outside AND has moved off the spot it
        // closed from. While the island retracts its rect is empty, so "outside" alone would
        // clear it and the still pointer would hover the panel open again.
        if !inside, ui.suppressHoverUntilExit,
           let at = ui.suppressHoverPointer, hypot(p.x - at.x, p.y - at.y) > 3 {
            ui.suppressHoverUntilExit = false
        }
        guard inside != mouseInside else { return }
        mouseInside = inside
        if !inside { Haptics.shared.resetHover() }
        updateHotKeys()
        insidePoll?.invalidate()
        insidePoll = nil
        if inside {
            insidePoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMouseState() }
            }
        }
        hoverTask?.cancel()
        let delay = inside ? Self.hoverInDelay : Self.hoverOutDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.applyHover(inside)
        }
    }

    private func applyHover(_ inside: Bool) {
        if isRetracting { return }
        if inside {
            LoginItem.shared.refresh()   // the ⚙ / right-click menu shows its current state
            if appState.readerSessionId != nil, panel?.isKeyWindow != true { requestKey() }
            if ui.suppressHoverUntilExit { return }   // just closed via the × button
            if case .finished(let ids) = currentPresentation { ui.stickyFinishedIds = ids }
            if currentPresentation == .awaySummary { ui.awaySummaryHovered = true }
            appState.setHovering(true)
        } else {
            // Keep everything open while the user is typing a reply.
            if ui.isEditing { return }
            ui.stickyFinishedIds = nil
            ui.replyTargetId = nil
            // "While you were away" stays until it has been looked at: hovered, then left.
            if ui.awaySummaryHovered {
                ui.awaySummaryHovered = false
                appState.dismissAwaySummary()
            }
            ui.readTarget = nil
            appState.setHovering(false)   // the reader is pinned: hover-out doesn't close it
            if panel?.isKeyWindow == true { releaseKey() }
        }
    }

    private func clickedOutside() {
        // Global monitors only see events for other apps' windows, i.e. outside our panel.
        if ui.isEditing || panel?.isKeyWindow == true { ui.releaseKey() }
        ui.dismissPrompt()   // setup prompts / update notice: a click elsewhere means "not now"
        ui.stickyFinishedIds = nil
        ui.replyTargetId = nil
        if appState.awaySummary != nil {
            // Grace period: the click that ended an idle stretch mustn't close it unseen.
            if let shown = ui.awaySummaryShownAt, Date().timeIntervalSince(shown) > Self.awayClickGrace {
                ui.awaySummaryHovered = false
                appState.dismissAwaySummary()
            }
        }
        if appState.readerSessionId != nil { appState.closeReader() }
        if appState.isPinnedExpanded { appState.collapse() }
        else if appState.isHovering && !mouseInside { appState.setHovering(false) }
    }

    // MARK: Haptics

    /// Feed the haptics director what the island shows now (open tap, needs-you taps, the
    /// turn-end burst synced to the mascot's jump; see HapticDirector).
    private func updateHaptics() {
        let surface: HapticSurface = (ui.islandShown && !isRetracting) ? currentPresentation.hapticSurface : .hidden
        var finished = Set<UUID>()
        for e in appState.events { if case .sessionFinished = e.kind { finished.insert(e.id) } }
        Haptics.shared.update(surface: surface, finishedEvents: finished)
    }

    // MARK: Key status

    func requestKey() {
        guard let panel else { return }
        panel.allowsKey = true
        panel.ignoresMouseEvents = false
        panel.makeKey()
    }

    func releaseKey() {
        guard let panel else { return }
        panel.allowsKey = false
        if panel.isKeyWindow {
            // Hand keyboard focus back to the frontmost app without hiding the island.
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        ui.isEditing = false
        updateMouseState()
    }

    // MARK: Hot keys

    /// ⌘↩ / esc are Carbon hot keys, which swallow the key system-wide while registered. Only arm
    /// them while the pointer is over the permission drop-down (or the panel is key), so a stray
    /// ⌘↩ (e.g. "send" in another app) can never approve a command and esc keeps working
    /// everywhere else.
    private func updateHotKeys() {
        let p = currentPresentation
        var pendingKind: RequestKind?
        var pendingId: UUID?
        if case .permission(let id) = p, let r = appState.permission(id: id) { pendingKind = r.kind; pendingId = id }
        // Click / hot-key guard: a request that just appeared (or the queue advanced to) ignores
        // actions for 400 ms (FreshContentGate).
        ui.needsYouShown(pendingId)
        if case .finished(let ids) = p { ui.finishedShown(ids) } else { ui.finishedShown(nil) }
        // Pointer-armed only after the pointer moved onto the drop-down (see HotKeyGate).
        let pointer = NSEvent.mouseLocation
        let pointerArmed = hotKeyGate.update(key: pendingKind != nil || p == .awaySummary ? p.kind : nil,
                                             pointerX: pointer.x, pointerY: pointer.y, inside: mouseInside)
        if let kind = pendingKind, kind != .permission, ui.isEditing {
            // Typing an answer / feedback: the keys belong to the text field (handleKeyDown
            // handles ⌘↩ and esc there).
            hotKeys.setMode(.off)
        } else if let kind = pendingKind, pointerArmed || panel?.isKeyWindow == true {
            hotKeys.setMode(kind == .question ? .question : .permission)
        }
        else if p == .awaySummary && pointerArmed { hotKeys.setMode(.escapeOnly) }
        else { hotKeys.setMode(.off) }
        // Remember when the away summary appeared (click-away grace period).
        if p == .awaySummary { if ui.awaySummaryShownAt == nil { ui.awaySummaryShownAt = Date() } }
        else if ui.awaySummaryShownAt != nil { ui.awaySummaryShownAt = nil; ui.awaySummaryHovered = false }
    }

    private func handleHotKey(_ action: PermissionHotKeys.Action) {
        if currentPresentation == .awaySummary {
            if action == .deny {
                ui.awaySummaryHovered = false
                appState.dismissAwaySummary()
            }
            return
        }
        guard case .permission(let id) = currentPresentation, let req = appState.permission(id: id) else { return }
        switch req.kind {
        case .question where req.questions != nil:
            if let n = action.digit { QuestionActions.pick(n - 1, appState: appState, ui: ui, request: req) }
            else if action == .allow { QuestionActions.primary(appState: appState, ui: ui, request: req) }
            else { QuestionActions.answerInTerminal(appState: appState, ui: ui, request: req) }
        case .plan where req.plan != nil:
            if action == .allow { QuestionActions.approvePlan(.manual, appState: appState, ui: ui, request: req) }
            else if action == .deny { QuestionActions.answerInTerminal(appState: appState, ui: ui, request: req) }
        default:
            guard action.digit == nil else { return }
            PermissionView.resolve(appState: appState, ui: ui, request: req,
                                   decision: action == .allow ? .allow : .deny)
        }
    }

    func tearDown() {
        insidePoll?.invalidate()
        hotKeys.setEnabled(false)
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        cancellables.removeAll()
    }
}
