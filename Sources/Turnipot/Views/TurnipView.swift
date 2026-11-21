import AppKit
import QuartzCore
import SwiftUI
import NotchCore

/// "Turnip" (default mascot): a turnip with a face sitting inside a small orange pot. The pot
/// front is drawn over the turnip and the turnip is clipped just below the rim, so only the part
/// above the rim shows; moods move it up / down relative to the rim (spring between moods).
/// Layout/motion numbers come from `TurnipRig` (NotchCore, self-tested). Live = Core Animation
/// (`TurnipNSView`), offscreen renders = Canvas (`TurnipArt.draw`).
///   sleeping: sunk in, only leaves + closed eyes show, breathes, drifting "z"
///   bouncing: peeks out, bobs, leaves sway, blinks
///   shake:    pops up, shakes, tall eyes + "o" mouth, twinkling amber "!"
///   hop:      ^^ eyes + smile, sparkles, leaves flap; springs right out of the pot and lands
///             with a squash in the finished drop-down (`.stage`), pops up a row in the strips
///   sweat:    sinks, wilted yellow leaves, worried face, sweat drop
struct TurnipMascotView: View {
    let mood: MascotMood
    let pixelSize: CGFloat
    var layout: TurnipRig.Layout = .compact
    var showZ: Bool = true

    @Environment(\.notchStaticRender) private var staticRender
    @Environment(\.mascotExtension) private var mascotExtension
    @Environment(\.mascotUsagePercent) private var usagePercent
    @Environment(\.mascotLoopTime) private var loopTime

    static func frameSize(pixelSize p: CGFloat, layout: TurnipRig.Layout) -> CGSize {
        CGSize(width: CGFloat(TurnipRig.frameColumns) * p, height: CGFloat(layout.rows) * p)
    }

    var body: some View {
        let size = Self.frameSize(pixelSize: pixelSize, layout: layout)
        Group {
            if staticRender {
                Canvas { ctx, _ in
                    TurnipArt.draw(in: &ctx, mood: mood, p: pixelSize, layout: layout, extension: mascotExtension,
                                   showZ: showZ, usage: usagePercent, time: loopTime)
                }
            } else {
                TurnipLayerView(mood: mood, pixelSize: pixelSize, layout: layout, showZ: showZ,
                                extended: mascotExtension > 0.5, usage: usagePercent)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityLabel("Turnipot mascot Turnip, \(mood.rawValue)")
    }
}

/// Pixel art shared by the Canvas and Core Animation paths. Turnip art is in "turnip space":
/// x = frame column (pot x + leftMargin), y = turnip-local row (0 = top of the leaves).
enum TurnipArt {
    typealias T = TurnipRig

    static var dx: CGFloat { CGFloat(T.leftMargin) }

    static func cg(_ r: TurnipRect, dy: CGFloat = 0) -> CGRect {
        CGRect(x: CGFloat(r.x) + dx, y: CGFloat(r.y) + dy, width: CGFloat(r.w), height: CGFloat(r.h))
    }

    /// Turnip cells grouped by colour key.
    static func groups(_ cells: [(TurnipRect, Character)]) -> [(Character, [CGRect])] {
        var order: [Character] = []
        var map: [Character: [CGRect]] = [:]
        for (r, ch) in cells {
            if map[ch] == nil { order.append(ch) }
            map[ch, default: []].append(cg(r))
        }
        return order.map { ($0, map[$0]!) }
    }

    /// Pot cells (frame coordinates; y relative to `rimRow`).
    static func potGroups(rimRow: Int) -> [(Character, [CGRect])] {
        groups(T.potRects.map { (TurnipRect($0.0.x, $0.0.y + Double(rimRow), 1, 1), $0.1) })
    }

    static func path(_ rects: [CGRect], p: CGFloat) -> CGPath {
        PixelPath.path(rects, p: p)
    }

    static func faceRects(_ face: T.Face) -> (eyes: [CGRect], mouth: [CGRect], tongue: [CGRect], blush: [CGRect]) {
        (T.eyeRects(face).map { cg($0) }, T.mouthRects(face).map { cg($0) },
         T.tongueRects(face).map { cg($0) }, T.blushRects(face).map { cg($0) })
    }

    static func pivot(_ mood: MascotMood) -> CGPoint {
        let pv = T.pivot(for: mood)
        return CGPoint(x: CGFloat(pv.x) + dx, y: CGFloat(pv.y))
    }
    static var leafPivot: CGPoint { CGPoint(x: CGFloat(T.leafPivot.x) + dx, y: CGFloat(T.leafPivot.y)) }
    /// Pot scale-in anchor: bottom centre of the pot (frame coordinates).
    static func potAnchor(_ layout: T.Layout) -> CGPoint {
        CGPoint(x: dx + CGFloat(T.potColumns) / 2, y: CGFloat(layout.rows))
    }

    static func zRects(rimRow: Int) -> [CGRect] { T.zRects.map { cg($0, dy: CGFloat(rimRow)) } }

    static func color(_ hex: UInt32, _ opacity: Double = 1) -> Color { Color(hex: hex, opacity: opacity) }

    /// Static pose (offscreen renders). `time` (render frames only) evaluates the finished
    /// spring / hop at that many seconds; nil = at rest.
    static func draw(in ctx: inout GraphicsContext, mood: MascotMood, p: CGFloat, layout: T.Layout,
                     extension e: Double, showZ: Bool, usage: Int?, time: Double?) {
        let w = CGFloat(T.frameColumns) * p
        let a = potAnchor(layout)
        ctx.opacity = T.potOpacity(extension: e)
        let s = CGFloat(T.potScale(extension: e))
        ctx.translateBy(x: a.x * p, y: a.y * p)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -a.x * p, y: -a.y * p)

        func fill(_ c: inout GraphicsContext, _ rects: [CGRect], _ hex: UInt32, _ opacity: Double = 1) {
            guard !rects.isEmpty else { return }
            c.fill(Path(path(rects, p: p)), with: .color(color(hex, opacity)))
        }

        let top = CGFloat(T.topRow(for: mood, layout: layout, extension: e))
        let pose = (mood == .hop && time != nil) ? T.finishedPose(at: time ?? 0, layout: layout) : .identity
        let shown = e >= 0.99

        // Turnip (clipped below the rim, behind the pot front).
        var clip = ctx
        clip.clip(to: Path(CGRect(x: -w, y: 0, width: 3 * w, height: CGFloat(layout.clipRow) * p)))
        var sparkles = clip
        var t = clip
        let pv = pivot(mood)
        t.translateBy(x: (pv.x + CGFloat(pose.dx)) * p, y: (top + pv.y + CGFloat(pose.dy)) * p)
        t.rotate(by: .degrees(pose.rot))
        t.scaleBy(x: CGFloat(pose.sx), y: CGFloat(pose.sy))
        t.translateBy(x: -pv.x * p, y: -pv.y * p)
        for (ch, rects) in groups(T.leafRects(wilted: mood == .sweat)) { fill(&t, rects, T.hex(for: ch, usage: usage)) }
        for (ch, rects) in groups(T.bulbRects) { fill(&t, rects, T.hex(for: ch, usage: usage)) }
        let f = faceRects(T.face(for: mood))
        fill(&t, f.blush, T.blushHex, 0.85)
        fill(&t, f.eyes, T.eyeHex)
        fill(&t, f.mouth, T.eyeHex)
        fill(&t, f.tongue, T.tongueHex)
        if shown {
            switch mood {
            case .shake: fill(&t, T.bangRects.map { cg($0) }, T.bangHex)
            case .sweat: fill(&t, T.dropRects.map { cg($0) }, T.dropHex)
            case .hop:
                let sp = T.sparklePose(pose, layout: layout)
                sparkles.translateBy(x: 0, y: (top + CGFloat(sp.dy)) * p)
                fill(&sparkles, T.sparkleRects.map { cg($0) }, T.sparkleHex)
            default: break
            }
        }

        // Pot front over the turnip.
        for (ch, rects) in potGroups(rimRow: layout.rimRow) { fill(&ctx, rects, T.hex(for: ch, usage: usage)) }
        if shown && mood == .sleeping && showZ { fill(&ctx, zRects(rimRow: layout.rimRow), T.zHex) }
    }
}

struct TurnipLayerView: NSViewRepresentable {
    let mood: MascotMood
    let pixelSize: CGFloat
    let layout: TurnipRig.Layout
    let showZ: Bool
    let extended: Bool
    let usage: Int?

    func makeNSView(context: Context) -> TurnipNSView {
        let v = TurnipNSView(pixelSize: pixelSize, layout: layout)
        v.apply(mood: mood, showZ: showZ, extended: extended, usage: usage)
        return v
    }

    func updateNSView(_ v: TurnipNSView, context: Context) {
        if v.pixelSize != pixelSize || v.layout != layout { v.rebuild(pixelSize: pixelSize, layout: layout) }
        v.apply(mood: mood, showZ: showZ, extended: extended, usage: usage)
    }
}

/// Core Animation Turnip. Layer tree (root clips to the frame):
///   whole              — opacity + scale (pot pops in at launch / fades at quit)
///     clip             — masks the turnip below `clipRow` (buried part hidden)
///       rest           — vertical position: mood height / buried (springs between them)
///         body         — mood loops (bob / breathe / shake / sink / spring), anchor = rim centre
///           leaves     — up / droop variants (sway / flap around the tuft's base)
///           bulb, faces (per mood; open eyes blink), "!", sweat drop
///         sparkles     — finished: follow the jump vertically, twinkle
///     pot front (rim, body, base) — drawn over the turnip
///     "z"
final class TurnipNSView: NSView {
    private(set) var pixelSize: CGFloat
    private(set) var layout: TurnipRig.Layout
    private var mood: MascotMood?
    private var showZ = false
    private var extended = true
    private var usage: Int?

    private let whole = CALayer()
    private let clip = CALayer()
    private let rest = CALayer()
    private let body = CALayer()
    private let leavesUp = CALayer()
    private let leavesDroop = CALayer()
    private var leafShapes: [CAShapeLayer] = []      // "g" leaves (usage colour)
    private var faces: [TurnipRig.Face: CALayer] = [:]
    private let openEyes = CAShapeLayer()
    private let bang = CAShapeLayer()
    private let drop = CAShapeLayer()
    private let sparkles = CAShapeLayer()
    private let zLayer = CAShapeLayer()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(pixelSize: CGFloat, layout: TurnipRig.Layout) {
        self.pixelSize = pixelSize
        self.layout = layout
        super.init(frame: CGRect(origin: .zero, size: TurnipMascotView.frameSize(pixelSize: pixelSize, layout: layout)))
        wantsLayer = true
        layer?.masksToBounds = true     // never draws outside its frame (= inside the island)
        rebuild(pixelSize: pixelSize, layout: layout)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { TurnipMascotView.frameSize(pixelSize: pixelSize, layout: layout) }

    private static func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha).cgColor
    }

    private var frameRect: CGRect { CGRect(origin: .zero, size: TurnipMascotView.frameSize(pixelSize: pixelSize, layout: layout)) }

    /// Make `l` frame-sized with its anchor at `pt` (sprite coordinates) so it scales/rotates there.
    private func anchor(_ l: CALayer, at pt: CGPoint) {
        let f = frameRect, p = pixelSize
        l.bounds = f
        l.anchorPoint = CGPoint(x: pt.x * p / f.width, y: pt.y * p / f.height)
        l.position = CGPoint(x: pt.x * p, y: pt.y * p)
    }

    func rebuild(pixelSize p: CGFloat, layout newLayout: TurnipRig.Layout) {
        pixelSize = p
        layout = newLayout
        guard let root = layer else { return }
        for l in [root, whole, clip, rest, body, leavesUp, leavesDroop] { l.sublayers?.forEach { $0.removeFromSuperlayer() } }
        for l in faces.values { l.sublayers?.forEach { $0.removeFromSuperlayer() } }
        [whole, rest, body, leavesUp, leavesDroop, openEyes, bang, drop, sparkles, zLayer].forEach { $0.removeAllAnimations() }
        setFrameSize(frameRect.size)

        let f = frameRect
        func shape(_ rects: [CGRect], _ hex: UInt32, _ alpha: CGFloat = 1, in parent: CALayer,
                   _ l: CAShapeLayer = CAShapeLayer()) -> CAShapeLayer {
            l.path = TurnipArt.path(rects, p: p)
            l.fillColor = Self.cg(hex, alpha)
            l.frame = f
            parent.addSublayer(l)
            return l
        }
        func plain(_ l: CALayer, in parent: CALayer) {
            l.anchorPoint = .zero; l.bounds = f; l.position = .zero
            parent.addSublayer(l)
        }

        root.addSublayer(whole)
        anchor(whole, at: TurnipArt.potAnchor(newLayout))
        clip.anchorPoint = .zero
        clip.bounds = CGRect(x: 0, y: 0, width: f.width, height: CGFloat(newLayout.clipRow) * p)
        clip.position = .zero
        clip.masksToBounds = true
        whole.addSublayer(clip)
        plain(rest, in: clip)
        rest.position = CGPoint(x: 0, y: CGFloat(TurnipRig.hiddenTop(layout: newLayout)) * p)
        rest.addSublayer(body)
        anchor(body, at: TurnipArt.pivot(.bouncing))

        leafShapes = []
        for (group, wilted) in [(leavesUp, false), (leavesDroop, true)] {
            body.addSublayer(group)
            anchor(group, at: TurnipArt.leafPivot)
            for (ch, rects) in TurnipArt.groups(TurnipRig.leafRects(wilted: wilted)) {
                let l = shape(rects, TurnipRig.hex(for: ch, usage: usage), in: group)
                if ch == "g" { leafShapes.append(l) }
            }
        }
        for (ch, rects) in TurnipArt.groups(TurnipRig.bulbRects) {
            _ = shape(rects, TurnipRig.hex(for: ch, usage: usage), in: body)
        }
        faces = [:]
        for face in TurnipRig.Face.allCases {
            let g = CALayer()
            plain(g, in: body)
            let r = TurnipArt.faceRects(face)
            _ = shape(r.blush, TurnipRig.blushHex, 0.85, in: g)
            if face == .open {
                _ = shape(r.eyes, TurnipRig.eyeHex, in: g, openEyes)
                let e = TurnipRig.eyes[0]
                anchor(openEyes, at: CGPoint(x: TurnipArt.pivot(.bouncing).x, y: CGFloat(e.1) + 0.5))   // blink around the eye row
            } else {
                _ = shape(r.eyes, TurnipRig.eyeHex, in: g)
            }
            _ = shape(r.mouth, TurnipRig.eyeHex, in: g)
            _ = shape(r.tongue, TurnipRig.tongueHex, in: g)
            g.isHidden = true
            faces[face] = g
        }
        _ = shape(TurnipRig.bangRects.map { TurnipArt.cg($0) }, TurnipRig.bangHex, in: body, bang)
        _ = shape(TurnipRig.dropRects.map { TurnipArt.cg($0) }, TurnipRig.dropHex, in: body, drop)
        _ = shape(TurnipRig.sparkleRects.map { TurnipArt.cg($0) }, TurnipRig.sparkleHex, in: rest, sparkles)

        for (ch, rects) in TurnipArt.potGroups(rimRow: newLayout.rimRow) {
            _ = shape(rects, TurnipRig.hex(for: ch, usage: usage), in: whole)
        }
        _ = shape(TurnipArt.zRects(rimRow: newLayout.rimRow), TurnipRig.zHex, in: whole, zLayer)

        invalidateIntrinsicContentSize()
        let m = mood; mood = nil
        if let m { apply(mood: m, showZ: showZ, extended: extended, usage: usage) }
    }

    private func restY(_ mood: MascotMood, extended: Bool) -> CGFloat {
        CGFloat(extended ? TurnipRig.restTop(for: mood, layout: layout) : TurnipRig.hiddenTop(layout: layout)) * pixelSize
    }

    func apply(mood newMood: MascotMood, showZ newShowZ: Bool, extended newExtended: Bool, usage newUsage: Int?) {
        let usageChanged = newUsage != usage
        guard newMood != mood || newShowZ != showZ || newExtended != extended || usageChanged else { return }
        let first = mood == nil
        let live = window != nil && !first
        let reduce = Self.reduceMotion
        let moodChanged = mood != newMood
        let extendChanged = newExtended != extended || first
        let oldY = rest.position.y
        let newY = restY(newMood, extended: newExtended)
        let p = pixelSize

        mood = newMood
        showZ = newShowZ
        extended = newExtended
        usage = newUsage

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if usageChanged {
            let c = Self.cg(TurnipRig.leafColor(forUsagePercent: newUsage))
            for l in leafShapes { l.fillColor = c }
        }

        // Pose / face for the mood.
        leavesUp.isHidden = newMood == .sweat
        leavesDroop.isHidden = newMood != .sweat
        let face = TurnipRig.face(for: newMood)
        for (k, l) in faces { l.isHidden = k != face }
        bang.isHidden = newMood != .shake || !newExtended
        drop.isHidden = newMood != .sweat || !newExtended
        sparkles.isHidden = newMood != .hop || !newExtended
        zLayer.isHidden = !(newMood == .sleeping && newShowZ && newExtended)
        anchor(body, at: TurnipArt.pivot(newMood))   // squash / twist around the rim centre

        let now = CACurrentMediaTime()
        if live && reduce && (moodChanged || extendChanged) {
            // Reduce Motion: plain fades (no rising / sinking).
            if extendChanged {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = whole.presentation()?.opacity ?? whole.opacity
                a.toValue = newExtended ? 1 : 0
                a.duration = 0.25
                whole.add(a, forKey: "show")
            } else {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.25
                body.add(fade, forKey: "moodFade")
                rest.add(fade, forKey: "moodFade")
            }
        } else if live && extendChanged {
            if newExtended {
                // Launch / switch-in: the pot pops in, then the turnip rises out of the soil.
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = whole.presentation()?.opacity ?? 0
                fadeIn.toValue = 1
                fadeIn.duration = 0.15
                whole.add(fadeIn, forKey: "show")
                let pop = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.3)
                pop.keyPath = "transform.scale"
                pop.fromValue = 0.6
                pop.toValue = 1
                pop.duration = pop.settlingDuration
                whole.add(pop, forKey: "pop")
                let rise = CASpringAnimation(perceptualDuration: IslandMotion.mascotDropResponse, bounce: 0.25)
                rise.keyPath = "position.y"
                rise.fromValue = rest.presentation()?.position.y ?? restY(newMood, extended: false)
                rise.toValue = newY
                rise.beginTime = now + 0.15
                rise.fillMode = .backwards
                rise.duration = rise.settlingDuration
                rest.add(rise, forKey: "slide")
            } else {
                // Quit / switch-out: the turnip sinks into the pot, then the pot fades.
                let sink = CABasicAnimation(keyPath: "position.y")
                sink.fromValue = rest.presentation()?.position.y ?? oldY
                sink.toValue = newY
                sink.duration = IslandMotion.mascotPullUpDuration
                sink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                rest.add(sink, forKey: "slide")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1; fade.toValue = 0
                fade.duration = 0.12
                fade.beginTime = now + IslandMotion.mascotPullUpDuration
                fade.fillMode = .backwards
                whole.add(fade, forKey: "show")
            }
        } else if live && moodChanged {
            // Mood change: spring up / down relative to the rim; cross-fade face + leaves.
            if oldY != newY {
                let spring = CASpringAnimation(perceptualDuration: IslandMotion.mascotDropResponse,
                                               bounce: IslandMotion.mascotDropBounce)
                spring.keyPath = "position.y"
                spring.fromValue = rest.presentation()?.position.y ?? oldY
                spring.toValue = newY
                spring.duration = spring.settlingDuration
                rest.add(spring, forKey: "slide")
            }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            body.add(fade, forKey: "moodFade")
            rest.add(fade, forKey: "moodFade")
        }
        rest.position = CGPoint(x: 0, y: reduce ? restY(newMood, extended: true) : newY)
        whole.opacity = newExtended ? 1 : 0

        let looped: [CALayer] = [body, leavesUp, leavesDroop, openEyes, bang, drop, sparkles, zLayer]
        for l in looped {
            l.removeAnimation(forKey: "loop")
            l.removeAnimation(forKey: "loop2")
        }
        if newExtended { addLoops(newMood, reduce: reduce, p: p) }
        CATransaction.commit()
    }

    private func addLoops(_ mood: MascotMood, reduce: Bool, p: CGFloat) {
        func forever(_ a: CAAnimation) -> CAAnimation {
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            return a
        }
        func keyframes(_ path: String, _ values: [Any], _ times: [Double], _ duration: Double) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values
            a.keyTimes = times.map { NSNumber(value: $0) }
            a.duration = duration
            return a
        }
        func pingPong(_ path: String, _ from: CGFloat, _ to: CGFloat, half: Double) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: path)
            a.fromValue = from; a.toValue = to
            a.duration = half; a.autoreverses = true
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        }
        let twinkle = keyframes("opacity", [1, 0.2, 1], [0, 0.5, 1], 1.0)
        twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        // Blink (working face); kept under Reduce Motion (not a positional loop).
        if TurnipRig.face(for: mood) == .open {
            openEyes.add(forever(keyframes("transform.scale.y", [1, 1, 0.1, 1], [0, 0.93, 0.96, 1], 3.4)), forKey: "loop")
        }
        if reduce { return }

        let sway = pingPong("transform.rotation.z", -CGFloat(TurnipRig.leafSway) * .pi / 180,
                            CGFloat(TurnipRig.leafSway) * .pi / 180, half: 1.1)
        switch mood {
        case .sleeping:
            body.add(forever(pingPong("transform.translation.y", 0, CGFloat(TurnipRig.breathe) * p, half: 1.3)), forKey: "loop")
            let move = CABasicAnimation(keyPath: "transform.translation")
            move.fromValue = NSValue(size: CGSize(width: 0, height: p))
            move.toValue = NSValue(size: CGSize(width: TurnipRig.zDrift.x * p, height: TurnipRig.zDrift.y * p))
            let g = CAAnimationGroup()
            g.animations = [move, keyframes("opacity", [0, 1, 0], [0, 0.5, 1], 2.2)]
            g.duration = 2.2
            zLayer.add(forever(g), forKey: "loop")
        case .bouncing:
            body.add(forever(pingPong("transform.translation.y", 0, -CGFloat(TurnipRig.bob) * p, half: 0.9)), forKey: "loop")
            leavesUp.add(forever(sway), forKey: "loop")
        case .shake:
            let k = CGFloat(TurnipRig.shakeX) * p
            body.add(forever(keyframes("transform.translation.x", [0, -k, 0, k, 0], [0, 0.25, 0.5, 0.75, 1], 0.24)), forKey: "loop")
            leavesUp.add(forever(sway), forKey: "loop")
            bang.add(forever(twinkle), forKey: "loop")
        case .sweat:
            let sink = CABasicAnimation(keyPath: "transform.translation")
            sink.fromValue = NSValue(size: .zero)
            sink.toValue = NSValue(size: CGSize(width: TurnipRig.sink.x * p, height: TurnipRig.sink.y * p))
            sink.duration = 1.5; sink.autoreverses = true
            sink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            body.add(forever(sink), forKey: "loop")
            let fall = CABasicAnimation(keyPath: "transform.translation.y")
            fall.fromValue = -p; fall.toValue = CGFloat(TurnipRig.dropFall) * p
            let g = CAAnimationGroup()
            g.animations = [fall, keyframes("opacity", [0, 1, 0], [0, 0.3, 1], 1.3)]
            g.duration = 1.3
            drop.add(forever(g), forKey: "loop")
        case .hop:
            addFinishedLoops(p: p, twinkle: twinkle)
        }
    }

    /// Finished: stage = the full spring-out (once shortly after the drop-down opens, then every
    /// `springPeriod`); strips = the small pop. Leaves flap during the jump and sway gently
    /// between jumps; sparkles twinkle (and follow the jump vertically on the stage).
    private func addFinishedLoops(p: CGFloat, twinkle: CAKeyframeAnimation) {
        let stage = layout == .stage
        let keys = TurnipRig.finishedKeyframes(layout: layout)
        let length = stage ? TurnipRig.springDuration : TurnipRig.hopDuration
        let period = stage ? TurnipRig.springPeriod : TurnipRig.hopDuration
        let begin = CACurrentMediaTime() + (stage ? TurnipRig.springDelay : 0)
        let times = keys.map { NSNumber(value: $0.time * length / period) } + (length < period ? [1] : [])
        let poses = keys.map(\.pose) + (length < period ? [TurnipRig.Pose.identity] : [])
        let curve = CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.4, 1)

        func transform(_ q: TurnipRig.Pose) -> CATransform3D {
            var t = CATransform3DMakeScale(CGFloat(q.sx), CGFloat(q.sy), 1)
            t = CATransform3DConcat(t, CATransform3DMakeRotation(CGFloat(q.rot) * .pi / 180, 0, 0, 1))
            return CATransform3DConcat(t, CATransform3DMakeTranslation(CGFloat(q.dx) * p, CGFloat(q.dy) * p, 0))
        }
        func timed(_ a: CAKeyframeAnimation) -> CAKeyframeAnimation {
            a.keyTimes = times
            a.duration = period
            a.timingFunctions = Array(repeating: curve, count: times.count - 1)
            a.beginTime = begin
            a.fillMode = .backwards
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            return a
        }
        let jump = CAKeyframeAnimation(keyPath: "transform")
        jump.values = poses.map { NSValue(caTransform3D: transform($0)) }
        body.add(timed(jump), forKey: "loop")

        // Leaves: fast flap while airborne (scale x 1.15 <-> 0.85 every 0.18s), then still.
        let flapEnd = keys.last(where: { $0.pose != .identity }).map { $0.time * length } ?? length
        var fv: [CGFloat] = [1], ft: [Double] = [0]
        var tt = 0.09, up = true
        while tt < flapEnd {
            fv.append(1 + (up ? 1 : -1) * CGFloat(TurnipRig.leafFlap)); ft.append(tt / period)
            up.toggle(); tt += 0.18
        }
        fv.append(1); ft.append(min(tt, period) / period)
        if ft.last! < 1 { fv.append(1); ft.append(1) }
        let flap = CAKeyframeAnimation(keyPath: "transform.scale.x")
        flap.values = fv
        flap.keyTimes = ft.map { NSNumber(value: $0) }
        flap.duration = period
        flap.beginTime = begin
        flap.repeatCount = .infinity
        flap.isRemovedOnCompletion = false
        leavesUp.add(flap, forKey: "loop")
        // Gentle happy sway between jumps.
        let sway = CABasicAnimation(keyPath: "transform.rotation.z")
        sway.fromValue = -4 * CGFloat.pi / 180; sway.toValue = 4 * CGFloat.pi / 180
        sway.duration = 0.8; sway.autoreverses = true
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sway.repeatCount = .infinity
        sway.isRemovedOnCompletion = false
        leavesUp.add(sway, forKey: "loop2")

        twinkle.repeatCount = .infinity
        twinkle.isRemovedOnCompletion = false
        sparkles.add(twinkle, forKey: "loop")
        if stage {
            let follow = CAKeyframeAnimation(keyPath: "transform.translation.y")
            follow.values = poses.map { CGFloat($0.dy) * p }
            sparkles.add(timed(follow), forKey: "loop2")
        }
    }
}
