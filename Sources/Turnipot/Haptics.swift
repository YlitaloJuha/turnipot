import AppKit
import SwiftUI
import NotchCore

/// Trackpad haptics (Force Touch trackpads; only felt while a finger rests on the trackpad).
/// Timing / throttling / gating is the pure `HapticScheduler` + `HapticDirector` in NotchCore;
/// this performs the taps with NSHapticFeedbackManager and persists the setting
/// (UserDefaults "haptics", default on; Reduce Motion doesn't turn it off).
///
/// Taps use `.now`: `.drawCompleted` waits for the app's next drawing pass, which may never come
/// for a timer-driven tap (observed: a `.drawCompleted` request from a windowless background
/// process never reached WindowServer, `.now` did).
@MainActor
final class Haptics: ObservableObject {
    static let shared = Haptics()
    static let defaultsKey = "haptics"

    @Published private(set) var isEnabled: Bool
    private var scheduler: HapticScheduler
    private var director = HapticDirector()
    private var pending: [Timer] = []
    /// TURNIPOT_HAPTICS_LOG=1: log every tap (you can't see haptics; this shows what would be felt).
    private let log = ProcessInfo.processInfo.environment["TURNIPOT_HAPTICS_LOG"] == "1"

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init(defaults: UserDefaults = .standard) {
        let on = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
        isEnabled = on
        scheduler = HapticScheduler(enabled: on)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.defaultsKey)
        isEnabled = on
        scheduler.enabled = on
        if on { perform(.alignment, why: "enabled") } else { cancelPending() }
    }

    /// The pointer moved onto a hover target (an action button).
    func hover(_ target: String) {
        if let p = scheduler.hover(target: target, at: now) { perform(p, why: "hover \(target)") }
    }

    /// The pointer left the island.
    func resetHover() { scheduler.resetHover() }

    /// Called by NotchWindowController after every state change.
    func update(surface: HapticSurface, finishedEvents: Set<UUID>) {
        let d = director.update(surface: surface, finishedEvents: finishedEvents)
        if d.cancelPending { cancelPending() }
        if d.resetHover { scheduler.resetHover() }
        if let cue = d.cue { play(cue) }
    }

    private func play(_ cue: HapticCue) {
        let start = now
        let steps = scheduler.cue(cue, at: start)
        for step in steps {
            if step.offset <= 0 {
                perform(step.pattern, why: "\(cue)")
                continue
            }
            // Common modes: keep firing while a menu / scroll tracks the run loop.
            let timer = Timer(timeInterval: step.offset, repeats: false) { [weak self] t in
                MainActor.assumeIsolated {
                    self?.pending.removeAll { $0 === t }
                    self?.perform(step.pattern, why: "\(cue) +\(String(format: "%.3f", step.offset))s")
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pending.append(timer)
        }
    }

    private func cancelPending() {
        guard !pending.isEmpty else { return }
        pending.forEach { $0.invalidate() }
        pending.removeAll()
        scheduler.cancelCue(at: now)
    }

    private func perform(_ p: HapticPattern, why: String) {
        guard isEnabled else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern
        switch p {
        case .generic: pattern = .generic
        case .alignment: pattern = .alignment
        case .levelChange: pattern = .levelChange
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        if log { NSLog("Turnipot haptic: %@ (%@)", p.rawValue, why) }
    }
}

extension Presentation {
    var hapticSurface: HapticSurface {
        switch self {
        case .collapsed: return .pill
        case .expanded: return .panel
        case .reader: return .reader
        case .finished(let ids): return .finished(sessionId: ids.first ?? "")
        case .permission(let id): return .needsYou(requestId: id)
        case .awaySummary: return .awaySummary
        case .nearLimit, .usageReset: return .nearLimit
        case .confirmation: return .confirmation
        }
    }
}

/// Light hover tick when the pointer moves onto this view. Only on action buttons (Allow / Deny,
/// question options, prompt buttons), not on rows, links or chrome. `id` defaults to a
/// per-view identity, so each button is its own target.
private struct HapticHover: ViewModifier {
    let id: String?
    @StateObject private var token = LocalState(UUID().uuidString)

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside { Haptics.shared.hover(id ?? token.value) }
        }
    }
}

extension View {
    func hapticHover(_ id: String? = nil) -> some View { modifier(HapticHover(id: id)) }
}
