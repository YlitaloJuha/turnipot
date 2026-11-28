import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import NotchCore

/// `Turnipot --export-media=<dir> [--fps=25]`: renders marketing visuals offscreen (no window,
/// no screen recording permission) from the made-up demo data in DemoMode, framed on a dark
/// wallpaper strip with a menu bar and the physical notch, at 2x:
///   hero.gif, finished.gif, permission.gif, reader.gif, reset.gif, reset-week.gif, away-reset.gif
///   (looping animated GIFs) and
///   expanded.png, question.png, plan.png, away.png, mascots.png, pills.png.
/// Animation frames use the same springs / timings as the live island (IslandMotion), like
/// `--render`'s anim/ frames.
@MainActor
enum MediaExport {
    static var requestedDir: String? {
        CommandLine.arguments.first { $0.hasPrefix("--export-media=") }.map { String($0.dropFirst("--export-media=".count)) }
    }

    static var fps: Double {
        CommandLine.arguments.first { $0.hasPrefix("--fps=") }.flatMap { Double($0.dropFirst("--fps=".count)) } ?? 25
    }

    typealias M = IslandMotion

    /// Screen and notch like a 14" MacBook Pro (points).
    static let geo: NotchGeometry = {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        return NotchGeometry(screenFrame: screen,
                             notchRect: CGRect(x: screen.midX - 92.5, y: screen.maxY - 32, width: 185, height: 32),
                             hasNotch: true)
    }()

    /// Width of the exported strip (points); the notch is centred in it.
    static let stageWidth: CGFloat = 820

    // MARK: Entry

    static func run(dir: String) -> Never {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let only = CommandLine.arguments.first { $0.hasPrefix("--only=") }.map { String($0.dropFirst("--only=".count)) }
        func want(_ name: String) -> Bool { only.map { $0.split(separator: ",").contains(Substring(name)) } ?? true }

        if want("hero") { writeGIF(heroFrames(), height: 372, to: url.appendingPathComponent("hero.gif")) }
        if want("finished") { writeGIF(finishedFrames(), height: 168, to: url.appendingPathComponent("finished.gif")) }
        if want("reset") { writeGIF(resetFrames(week: false), height: 156, to: url.appendingPathComponent("reset.gif")) }
        if want("reset-week") { writeGIF(resetFrames(week: true), height: 156, to: url.appendingPathComponent("reset-week.gif")) }
        if want("away-reset") { writeGIF(awayResetFrames(), height: 236, to: url.appendingPathComponent("away-reset.gif")) }
        if want("permission") { writeGIF(permissionFrames(), height: 196, to: url.appendingPathComponent("permission.gif")) }
        if want("reader") { writeGIF(readerFrames(), height: 604, to: url.appendingPathComponent("reader.gif")) }

        if want("expanded") { writeStill(state: "expanded", height: 372, to: url.appendingPathComponent("expanded.png")) }
        if want("question") { writeStill(state: "question", height: 400, to: url.appendingPathComponent("question.png")) }
        if want("plan") { writeStill(state: "plan", height: 604, to: url.appendingPathComponent("plan.png")) }
        if want("away") { writeStill(state: "away", height: 236, to: url.appendingPathComponent("away.png")) }
        if want("mascots") { writePNG(MascotGrid(), to: url.appendingPathComponent("mascots.png")) }
        if want("pills") { writePNG(pillsView(), to: url.appendingPathComponent("pills.png")) }
        exit(0)
    }

    // MARK: Frame model

    /// One rendered frame: an island state (optionally an explicit animation frame), the pointer
    /// position (stage coordinates) and the reader's simulated scroll offset.
    @MainActor struct Frame {
        var app: AppState
        var ui: NotchUIState
        var override: IslandFrameOverride?
        var pointer: CGPoint? = nil
        var scroll: CGFloat = 0
    }

    @MainActor struct Scene {
        let app: AppState
        let ui: NotchUIState
        init(_ demo: String) {
            app = AppState()
            DemoMode.apply(demo, to: app)
            ui = NotchUIState(geometry: MediaExport.geo)
        }
        var collapsed: Presentation { .collapsed(wing: PillLayout.wing(appState: app, ui: ui)) }
        var current: Presentation { Presentation.current(appState: app, ui: ui) }
        func shape(_ p: Presentation) -> IslandShapeState {
            IslandShapeState(size: p.bodySize(appState: app, ui: ui), radius: p.bottomRadius,
                             rightTrim: p.rightTrim(appState: app))
        }
        func still(_ p: Presentation, mascotTime: Double? = nil) -> IslandFrameOverride {
            var o = IslandFrameOverride(shape: shape(p), content: p, contentOpacity: 1)
            o.mascotTime = mascotTime
            return o
        }
    }

    /// Grow (expand / drop-down): the shape springs with a slight overshoot; old content fades
    /// out, new content fades / scales in. `fromShape` may come from another scene (the pill
    /// before a session finished).
    static func grow(_ s: Scene, from: Presentation, fromShape: IslandShapeState? = nil, to: Presentation, t: Double) -> IslandFrameOverride {
        let f = M.progress(M.growSpring, t: t)
        let shape = (fromShape ?? s.shape(from)).interpolated(to: s.shape(to), f)
        return transition(shape: shape, from: from, to: to, t: t)
    }

    static func shrink(_ s: Scene, from: Presentation, to: Presentation, t: Double) -> IslandFrameOverride {
        let f = M.progress(M.shrinkSpring, t: t, delay: M.shrinkDelay)
        let shape = s.shape(from).interpolated(to: s.shape(to), f)
        return transition(shape: shape, from: from, to: to, t: t)
    }

    private static func transition(shape: IslandShapeState, from: Presentation, to: Presentation, t: Double) -> IslandFrameOverride {
        if t < M.contentOutDuration {
            return IslandFrameOverride(shape: shape, content: from, contentOpacity: 1 - t / M.contentOutDuration, transitionOnly: true)
        }
        let c = M.contentInProgress(t: t)
        return IslandFrameOverride(shape: shape, content: to, contentOpacity: c,
                                   contentScale: 0.94 + 0.06 * CGFloat(c), contentOffset: -6 * CGFloat(1 - c),
                                   transitionOnly: true)
    }

    /// Frames for `seconds` of a segment; `make` gets the segment-local time.
    static func segment(_ seconds: Double, _ make: (Double) -> Frame) -> [Frame] {
        let n = max(1, Int((seconds * fps).rounded()))
        return (0..<n).map { make(Double($0) / fps) }
    }

    static func ease(_ x: Double) -> Double { let u = min(max(x, 0), 1); return u * u * (3 - 2 * u) }
    static func lerp(_ a: CGPoint, _ b: CGPoint, _ f: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Stage x of the notch's centre.
    static var mid: CGFloat { stageWidth / 2 }

    // MARK: GIF scripts

    /// Launch (pill springs out of the notch, the turnip rises out of its pot), the pointer moves
    /// onto the island, hover-expand into the panel, then collapse.
    static func heroFrames() -> [Frame] {
        let s = Scene("expanded")
        let hidden = IslandShapeState.hidden(geo)
        let pill = s.collapsed
        let p0 = CGPoint(x: mid + 250, y: 300), p1 = CGPoint(x: mid + 40, y: 18), p2 = CGPoint(x: mid + 230, y: 340)
        var frames: [Frame] = []
        frames += segment(0.25) { _ in Frame(app: s.app, ui: s.ui, override: hiddenFrame(hidden, pill)) }
        frames += segment(1.0) { t in
            let f = M.progress(M.launchSpring, t: t)
            let c = M.contentInProgress(t: t)
            let o = IslandFrameOverride(shape: hidden.interpolated(to: s.shape(pill), f), content: pill, contentOpacity: c,
                                        contentScale: 0.92 + 0.08 * CGFloat(c),
                                        mascotExtension: M.progress(M.mascotDropSpring, t: t, delay: M.mascotDropDelay))
            return Frame(app: s.app, ui: s.ui, override: o, pointer: p0)
        }
        frames += segment(0.5) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(pill), pointer: lerp(p0, p1, ease(t / 0.5)))
        }
        frames += segment(0.7) { t in
            Frame(app: s.app, ui: s.ui, override: grow(s, from: pill, to: .expanded, t: t), pointer: p1)
        }
        frames += segment(0.7) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(.expanded), pointer: lerp(p1, CGPoint(x: mid - 60, y: 120), ease(t / 0.7)))
        }
        frames += segment(0.25) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(.expanded), pointer: lerp(CGPoint(x: mid - 60, y: 120), p2, ease(t / 0.25)))
        }
        frames += segment(0.5) { t in
            Frame(app: s.app, ui: s.ui, override: shrink(s, from: .expanded, to: pill, t: t), pointer: p2)
        }
        frames += segment(0.1) { _ in Frame(app: s.app, ui: s.ui, override: s.still(pill), pointer: p2) }
        return frames
    }

    private static func hiddenFrame(_ hidden: IslandShapeState, _ pill: Presentation) -> IslandFrameOverride {
        IslandFrameOverride(shape: hidden, content: pill, contentOpacity: 0, mascotExtension: 0)
    }

    /// Working pill -> a session finishes: the drop-down grows out of the notch and the turnip
    /// springs out of its pot, twists and lands; then it folds back up.
    static func finishedFrames() -> [Frame] {
        let before = Scene("working")
        let s = Scene("finished")
        let drop = s.current
        var frames: [Frame] = []
        frames += segment(0.35) { _ in Frame(app: before.app, ui: before.ui, override: before.still(before.collapsed)) }
        frames += segment(0.5) { t in
            Frame(app: s.app, ui: s.ui, override: grow(s, from: s.collapsed, fromShape: before.shape(before.collapsed), to: drop, t: t))
        }
        frames += segment(TurnipRig.springDuration + 0.05) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(drop, mascotTime: min(t, TurnipRig.springDuration)))
        }
        frames += segment(0.55) { t in Frame(app: s.app, ui: s.ui, override: shrink(s, from: drop, to: before.collapsed, t: t)) }
        return frames
    }

    /// A usage window resets: the pill (near the limit) grows into the usage-reset drop-down, the
    /// turnip gets watered while the bar drains, then it folds back into the pill.
    static func resetFrames(week: Bool) -> [Frame] {
        let before = Scene(week ? "reset-week-before" : "reset-before")
        let s = Scene(week ? "usage-reset-week" : "usage-reset")
        let drop = Presentation.usageReset
        var frames: [Frame] = []
        frames += segment(0.6) { _ in Frame(app: before.app, ui: before.ui, override: before.still(before.collapsed)) }
        frames += segment(0.5) { t in
            var o = grow(s, from: s.collapsed, fromShape: before.shape(before.collapsed), to: drop, t: t)
            o.mascotTime = -1   // not watering yet; the bar stays at the old percent
            return Frame(app: s.app, ui: s.ui, override: o)
        }
        frames += segment(WaterRig.duration + 1.2) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(drop, mascotTime: t))
        }
        frames += segment(0.55) { t in Frame(app: s.app, ui: s.ui, override: shrink(s, from: drop, to: s.collapsed, t: t)) }
        frames += segment(0.4) { _ in Frame(app: s.app, ui: s.ui, override: s.still(s.collapsed)) }
        return frames
    }

    /// Back from being away: the "While you were away" summary lists a usage reset among the
    /// finished sessions (time order); the strip turnip gets watered as it opens.
    static func awayResetFrames() -> [Frame] {
        let s = Scene("away-reset")
        let drop = s.current
        var frames: [Frame] = []
        frames += segment(0.5) { _ in Frame(app: s.app, ui: s.ui, override: s.still(s.collapsed)) }
        frames += segment(0.5) { t in
            var o = grow(s, from: s.collapsed, to: drop, t: t)
            o.mascotTime = -1
            return Frame(app: s.app, ui: s.ui, override: o)
        }
        frames += segment(WaterRig.duration + 1.5) { t in Frame(app: s.app, ui: s.ui, override: s.still(drop, mascotTime: t)) }
        return frames
    }

    /// A permission request drops down with Allow / Always allow / Deny; the pointer clicks Allow.
    static func permissionFrames() -> [Frame] {
        let before = Scene("working")
        let s = Scene("permission")
        let drop = s.current
        let start = CGPoint(x: mid + 150, y: 178), allow = CGPoint(x: mid - 222, y: 112)
        var frames: [Frame] = []
        frames += segment(0.5) { _ in Frame(app: before.app, ui: before.ui, override: before.still(before.collapsed), pointer: start) }
        frames += segment(0.6) { t in
            Frame(app: s.app, ui: s.ui, override: grow(s, from: s.collapsed, fromShape: before.shape(before.collapsed), to: drop, t: t),
                  pointer: start)
        }
        frames += segment(0.6) { _ in Frame(app: s.app, ui: s.ui, override: s.still(drop), pointer: start) }
        frames += segment(0.8) { t in Frame(app: s.app, ui: s.ui, override: s.still(drop), pointer: lerp(start, allow, ease(t / 0.8))) }
        frames += segment(0.4) { _ in Frame(app: s.app, ui: s.ui, override: s.still(drop), pointer: allow) }
        frames += segment(0.6) { t in
            let f = M.progress(M.shrinkSpring, t: t, delay: M.shrinkDelay)
            let shape = s.shape(drop).interpolated(to: before.shape(before.collapsed), f)
            if t < M.contentOutDuration {   // the drop-down's content fades out (scene s) ...
                let o = IslandFrameOverride(shape: shape, content: drop, contentOpacity: 1 - t / M.contentOutDuration, transitionOnly: true)
                return Frame(app: s.app, ui: s.ui, override: o, pointer: allow)
            }                               // ... then the working pill fades back in
            let c = M.contentInProgress(t: t)
            let o = IslandFrameOverride(shape: shape, content: before.collapsed, contentOpacity: c, transitionOnly: true)
            return Frame(app: before.app, ui: before.ui, override: o, pointer: allow)
        }
        frames += segment(0.3) { _ in Frame(app: before.app, ui: before.ui, override: before.still(before.collapsed), pointer: allow) }
        return frames
    }

    static let readerScroll: CGFloat = 104

    /// Expanded panel -> click a row's ≡ to open the reply reader -> scroll through the reply.
    static func readerFrames() -> [Frame] {
        let s = Scene("reader")
        s.ui.readerTurns = DemoMode.readerTurns()
        s.ui.readerTurnsSessionId = "demo-api-refactor"
        let reader = Presentation.reader(sessionId: "demo-api-refactor")
        // The ≡ button on the "Refactor payment API" row (the pointer's tip sits on it).
        let row = CGPoint(x: mid - 18, y: 118), inReader = CGPoint(x: mid + 120, y: 260)
        var frames: [Frame] = []
        frames += segment(0.7) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(.expanded), pointer: lerp(CGPoint(x: mid + 160, y: 230), row, ease(t / 0.7)))
        }
        frames += segment(0.35) { _ in   // rest on ≡, then click
            Frame(app: s.app, ui: s.ui, override: s.still(.expanded), pointer: row)
        }
        frames += segment(0.7) { t in Frame(app: s.app, ui: s.ui, override: grow(s, from: .expanded, to: reader, t: t), pointer: row) }
        frames += segment(0.3) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(reader), pointer: lerp(row, inReader, ease(t / 0.3)))
        }
        frames += segment(1.2) { t in
            Frame(app: s.app, ui: s.ui, override: s.still(reader), pointer: inReader, scroll: readerScroll * ease(t / 1.2))
        }
        frames += segment(0.7) { _ in Frame(app: s.app, ui: s.ui, override: s.still(reader), pointer: inReader, scroll: readerScroll) }
        return frames
    }

    // MARK: Stage (wallpaper + menu bar + notch + island)

    @MainActor struct Stage: View {
        let frame: Frame
        let height: CGFloat
        /// GIF frames: plain gradient wallpaper (soft blobs band badly in a 256-colour palette).
        var plain = false

        var body: some View {
            let g = MediaExport.geo
            let panel = g.panelFrame.size
            let panelX = MediaExport.mid - (g.notchRect.midX - g.panelFrame.minX)
            ZStack(alignment: .topLeading) {
                Wallpaper(plain: plain)
                MenuBar(height: g.notchHeight)
                UnevenRoundedRectangle(bottomLeadingRadius: NotchGeometry.collapsedBottomRadius,
                                       bottomTrailingRadius: NotchGeometry.collapsedBottomRadius)
                    .fill(Color.black)
                    .frame(width: g.notchRect.width, height: g.notchHeight)
                    .offset(x: MediaExport.mid - g.notchRect.width / 2)
                IslandView(appState: frame.app, ui: frame.ui, frameOverride: frame.override)
                    .environment(\.renderScrollOffset, frame.scroll)
                    .frame(width: panel.width, height: panel.height)
                    .offset(x: panelX)
                if let p = frame.pointer {
                    Pointer().offset(x: p.x, y: p.y)
                }
            }
            .frame(width: MediaExport.stageWidth, height: height, alignment: .topLeading)
            .clipped()
            .environment(\.colorScheme, .dark)
            .environment(\.notchStaticRender, true)
        }
    }

    /// Dark, soft macOS-like wallpaper.
    struct Wallpaper: View {
        var plain = false
        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1b1530), Color(hex: 0x2a1f45), Color(hex: 0x123a48)],
                               startPoint: .bottomLeading, endPoint: .topTrailing)
                if !plain {
                RadialGradient(colors: [Color(hex: 0xd97757).opacity(0.22), .clear], center: UnitPoint(x: 0.18, y: 0.9),
                               startRadius: 0, endRadius: 420)
                RadialGradient(colors: [Color(hex: 0x3fb5a6).opacity(0.16), .clear], center: UnitPoint(x: 0.88, y: 0.15),
                               startRadius: 0, endRadius: 380)
                }
            }
        }
    }

    /// Translucent menu bar with a few generic items on both sides of the notch.
    struct MenuBar: View {
        let height: CGFloat
        var body: some View {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.32))
                HStack(spacing: 15) {
                    Image(systemName: "apple.logo").font(.system(size: 13, weight: .medium))
                    Text("Terminal").font(.system(size: 13, weight: .bold))
                    Text("Shell")
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Text("Thu 9:41")
                }
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.horizontal, 16)
            }
            .frame(height: height)
        }
    }

    /// Classic arrow pointer (black with a white outline).
    struct Pointer: View {
        var body: some View {
            let path = Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: 17))
                p.addLine(to: CGPoint(x: 4.2, y: 13))
                p.addLine(to: CGPoint(x: 7.2, y: 19.6))
                p.addLine(to: CGPoint(x: 10, y: 18.4))
                p.addLine(to: CGPoint(x: 7.1, y: 12))
                p.addLine(to: CGPoint(x: 12.6, y: 12))
                p.closeSubpath()
            }
            ZStack(alignment: .topLeading) {
                path.fill(Color.black)
                path.stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
            .frame(width: 14, height: 21, alignment: .topLeading)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        }
    }

    // MARK: Stills

    static func writeStill(state: String, height: CGFloat, to url: URL) {
        let s = Scene(state)
        if state == "question", let req = s.app.currentPermission {
            s.ui.updateDraft(for: req) { $0.selections[0].toggle(0, multiSelect: false) }
        }
        writePNG(Stage(frame: Frame(app: s.app, ui: s.ui, override: nil), height: height), to: url)
    }

    /// Idle / working / "2 done" pills stacked, each on its own strip.
    static func pillsView() -> some View {
        let rows: [(String, String)] = [("idle", "Idle: the turnip naps in its pot"),
                                        ("working", "Working: busy sessions + usage rings"),
                                        ("unseen", "Finished while you looked away")]
        return VStack(spacing: 0) {
            ForEach(rows, id: \.0) { demo, label in
                let s = Scene(demo)
                ZStack(alignment: .bottomLeading) {
                    Stage(frame: Frame(app: s.app, ui: s.ui, override: s.still(s.collapsed)), height: 84)
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .padding(.leading, 18).padding(.bottom, 12)
                }
            }
        }
        .frame(width: stageWidth)
    }

    /// The turnip in each mood.
    struct MascotGrid: View {
        let moods: [(MascotMood, String)] = [(.sleeping, "Idle"), (.bouncing, "Working"), (.hop, "Finished"),
                                             (.shake, "Needs you"), (.sweat, "Near limit")]
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(moods, id: \.1) { _, label in
                        Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))
                            .frame(width: 118)
                    }
                }
                HStack(spacing: 12) {
                    ForEach(moods, id: \.1) { mood, _ in
                        tile(mood)
                    }
                }
            }
            .padding(24)
            .background(Wallpaper())
            .environment(\.colorScheme, .dark)
            .environment(\.notchStaticRender, true)
        }

        func tile(_ mood: MascotMood) -> some View {
            let p: CGFloat = 4
            return MascotView(mood: mood, pixelSize: p)
                .environment(\.mascotStripHeight, CGFloat(TurnipRig.Layout.compact.rows) * p)
                .environment(\.mascotUsagePercent, mood == .sweat ? 92 : 30)
                .environment(\.mascotExtension, 1)
                .frame(width: 118, height: 84)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18).fill(Color.black))
        }
    }

    // MARK: Writers

    static func cgImage<V: View>(_ view: V) -> CGImage? {
        let r = ImageRenderer(content: view)
        r.scale = 2
        return r.cgImage
    }

    static func writePNG<V: View>(_ view: V, to url: URL) {
        guard let img = cgImage(view),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("export failed: \(url.lastPathComponent)"); return
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        report(url, "\(img.width)x\(img.height)")
    }

    /// Writes an endlessly looping GIF; identical consecutive frames are merged (longer delay).
    static func writeGIF(_ frames: [Frame], height: CGFloat, to url: URL) {
        var images: [(CGImage, Double)] = []
        var lastData: Data?
        let dt = 1 / fps
        for f in frames {
            guard let img = cgImage(Stage(frame: f, height: height, plain: true)) else { continue }
            let data = (img.dataProvider?.data as Data?) ?? Data()
            if data == lastData, !images.isEmpty {
                images[images.count - 1].1 += dt
            } else {
                images.append((img, dt))
                lastData = data
            }
        }
        guard let first = images.first,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else {
            print("export failed: \(url.lastPathComponent)"); return
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (img, delay) in images {
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                         kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(dest, img, props)
        }
        CGImageDestinationFinalize(dest)
        let total = images.reduce(0) { $0 + $1.1 }
        report(url, String(format: "%dx%d, %d frames (%d unique), %.2f s", first.0.width, first.0.height,
                           frames.count, images.count, total))
    }

    static func report(_ url: URL, _ detail: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        print(String(format: "%@  %@  %.0f KB", url.path, detail, Double(size) / 1024))
    }
}

struct RenderScrollOffsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Offscreen renders only: how far the reader's static scroll stand-in is scrolled (points).
    var renderScrollOffset: CGFloat {
        get { self[RenderScrollOffsetKey.self] }
        set { self[RenderScrollOffsetKey.self] = newValue }
    }
}
