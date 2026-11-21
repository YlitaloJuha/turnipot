import AppKit
import QuartzCore
import SwiftUI
import NotchCore

/// Rendering switch: offscreen ImageRenderer (`--render`) cannot draw NSViews, so views fall back
/// to static SwiftUI drawing when this is true.
struct StaticRenderKey: EnvironmentKey { static let defaultValue = false }
/// How far the turnip is out of its pot: 1 = at rest, 0 = sunk out of sight (launch / quit). Set by IslandView from NotchUIState.mascotRetracted (or a render frame override).
struct MascotExtensionKey: EnvironmentKey { static let defaultValue: Double = 1 }
/// Weekly usage percent (the turnip's leaf colour shifts subtly towards olive as it rises).
struct MascotUsageKey: EnvironmentKey { static let defaultValue: Int? = nil }
/// Height of the notch strip the mascot sits in (Turnip shrinks its pixels if 2pt don't fit).
struct MascotStripHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 32 }
/// Offscreen render frames only: seconds into the mascot's loop (Turnip's finished spring-out).
struct MascotLoopTimeKey: EnvironmentKey { static let defaultValue: Double? = nil }
extension EnvironmentValues {
    var mascotStripHeight: CGFloat {
        get { self[MascotStripHeightKey.self] }
        set { self[MascotStripHeightKey.self] = newValue }
    }
    var mascotLoopTime: Double? {
        get { self[MascotLoopTimeKey.self] }
        set { self[MascotLoopTimeKey.self] = newValue }
    }
    var mascotUsagePercent: Int? {
        get { self[MascotUsageKey.self] }
        set { self[MascotUsageKey.self] = newValue }
    }
    var notchStaticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
    var mascotExtension: Double {
        get { self[MascotExtensionKey.self] }
        set { self[MascotExtensionKey.self] = newValue }
    }
}


/// Pulsing glowing dot as a CALayer (opacity animation runs in the render server).
struct PulseDotLayerView: NSViewRepresentable {
    let color: NSColor
    let period: Double

    func makeNSView(context: Context) -> PulseDotNSView { PulseDotNSView(color: color, period: period) }
    func updateNSView(_ v: PulseDotNSView, context: Context) { v.configure(color: color, period: period) }
}

final class PulseDotNSView: NSView {
    private let dot = CALayer()
    private var color: NSColor?
    private var period: Double = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    init(color: NSColor, period: Double) {
        super.init(frame: CGRect(x: 0, y: 0, width: 7, height: 7))
        wantsLayer = true
        layer?.masksToBounds = false
        dot.frame = CGRect(x: 0, y: 0, width: 7, height: 7)
        dot.cornerRadius = 3.5
        dot.shadowOffset = .zero
        dot.shadowRadius = 3
        dot.shadowOpacity = 1
        layer?.addSublayer(dot)
        configure(color: color, period: period)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(color: NSColor, period: Double) {
        guard color != self.color || period != self.period else { return }
        if let old = self.color, old != color, window != nil {
            // Status change: cross-fade the dot colour instead of snapping.
            for key in ["backgroundColor", "shadowColor"] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = old.cgColor
                a.toValue = color.cgColor
                a.duration = 0.25
                dot.add(a, forKey: "fade-" + key)
            }
        }
        self.color = color
        self.period = period
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        dot.shadowColor = color.cgColor
        dot.removeAnimation(forKey: "pulse")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.35
        pulse.duration = period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
        CATransaction.commit()
    }
}
