import AppKit
import SwiftUI
import NotchCore

/// Screen/notch measurements and per-mode island sizes. All values in points, AppKit
/// screen coordinates (origin bottom-left) unless noted.
struct NotchGeometry: Equatable {
    /// The screen the island lives on (built-in display with notch, else main).
    var screenFrame: CGRect
    /// Physical notch rect in screen coords; synthesized (centered) if the screen has no notch.
    var notchRect: CGRect
    var hasNotch: Bool
    /// Height of the screen's visible frame (menu bar / Dock excluded); nil = screen height.
    var visibleHeight: CGFloat? = nil

    /// Height of the top screen strip occupied by the notch (safeAreaInsets.top, or menu bar height).
    var notchHeight: CGFloat { notchRect.height }

    static let shoulderRadius: CGFloat = 8          // concave curve where island meets top edge
    static let collapsedBottomRadius: CGFloat = 8
    static let openBottomRadius: CGFloat = 24
    /// Wing width (each side of the notch) while something is going on (working / near limit).
    static let collapsedWingWidth: CGFloat = 74
    /// Wing width when idle: pill barely wider than the notch (mockup state 1).
    static let idleWingWidth: CGFloat = 44
    /// Drop-down sizes. Heights here are the body below the notch strip (see islandSize).
    static let finishedSize = CGSize(width: 540, height: 124)
    static let finishedCompactSize = CGSize(width: 420, height: 34)
    static let permissionSize = CGSize(width: 560, height: 114)
    static let expandedSize = CGSize(width: 600, height: 440)   // max; actual height is content-driven
    static let nearLimitSize = CGSize(width: 380, height: 58)
    static let confirmationSize = CGSize(width: 300, height: 34)
    /// Setup prompts / update notice (confirmation with lines and buttons).
    static let promptWidth: CGFloat = 520
    /// "While you were away" drop-down width (height is content-driven, see AwaySummaryMetrics).
    static let awaySummaryWidth: CGFloat = 470
    /// Reply reader: as wide as the expanded panel, up to this tall (whole island, strip included),
    /// and never more than `readerScreenFraction` of the screen's visible height.
    static let readerWidth: CGFloat = 600
    /// Question (AskUserQuestion) and plan (ExitPlanMode) drop-downs: as wide as the reader;
    /// heights are content-driven, capped like the reader's.
    static let questionWidth: CGFloat = 600
    static let readerMaxHeight: CGFloat = 560
    static let readerScreenFraction: CGFloat = 0.6
    /// Tallest the reader may get on this screen.
    var readerMaxHeight: CGFloat {
        min(Self.readerMaxHeight, ((visibleHeight ?? (screenFrame.height - notchHeight)) * Self.readerScreenFraction).rounded())
    }
    /// Collapsed wings never grow wider than this for the unseen badge (falls back to "N new").
    static let maxCollapsedWingWidth: CGFloat = 132

    /// Fallback notch for screens without one (small pill at top center).
    static let syntheticNotchWidth: CGFloat = 120

    /// Find the built-in notched screen (safeAreaInsets.top > 0 with auxiliary top areas),
    /// or fall back to the primary screen with a synthesized notch.
    @MainActor static func current() -> NotchGeometry {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        if let screen = notched {
            let frame = screen.frame
            let h = screen.safeAreaInsets.top
            var notchMinX = frame.midX - 92.5
            var notchWidth: CGFloat = 185
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                // The auxiliary areas are the usable strips left/right of the notch. Their widths
                // are robust regardless of whether the rects are screen-relative or global.
                let w = frame.width - left.width - right.width
                if w > 40 && w < frame.width / 2 {
                    notchWidth = w
                    notchMinX = frame.minX + left.width
                }
            }
            return NotchGeometry(
                screenFrame: frame,
                notchRect: CGRect(x: notchMinX, y: frame.maxY - h, width: notchWidth, height: h),
                hasNotch: true, visibleHeight: screen.visibleFrame.height)
        }
        // screens.first is the primary display (the one with the menu bar). NSScreen.main follows
        // the key window and would make the island jump between displays.
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = screen?.visibleFrame ?? frame
        var h = frame.maxY - visible.maxY                 // menu bar height (0 if auto-hidden)
        if h < 20 || h > 50 { h = 24 }
        let w = syntheticNotchWidth
        return NotchGeometry(
            screenFrame: frame,
            notchRect: CGRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h),
            hasNotch: false, visibleHeight: visible.height)
    }

    /// Body size of the island for a mode (excluding the shoulders). Collapsed = notch width +
    /// 2 wings at notch height; drop-downs = notch strip + content body.
    func islandSize(for mode: IslandMode) -> CGSize {
        switch mode {
        case .collapsed: return collapsedSize(wide: true)
        case .finished: return CGSize(width: Self.finishedSize.width, height: notchHeight + Self.finishedSize.height)
        case .permission: return CGSize(width: Self.permissionSize.width, height: notchHeight + Self.permissionSize.height)
        case .expanded: return CGSize(width: Self.expandedSize.width, height: 300)
        case .nearLimit: return CGSize(width: Self.nearLimitSize.width, height: notchHeight + Self.nearLimitSize.height)
        case .awaySummary: return CGSize(width: Self.awaySummaryWidth, height: notchHeight + 120)
        case .reader: return CGSize(width: Self.readerWidth, height: readerMaxHeight)
        }
    }

    func collapsedSize(wide: Bool) -> CGSize {
        collapsedSize(wing: wide ? Self.collapsedWingWidth : Self.idleWingWidth)
    }

    func collapsedSize(wing: CGFloat) -> CGSize {
        CGSize(width: notchRect.width + 2 * wing, height: notchHeight)
    }

    func bottomRadius(for mode: IslandMode) -> CGFloat {
        mode == .collapsed ? Self.collapsedBottomRadius : Self.openBottomRadius
    }

    /// "Hidden" island body (launch start / quit end, drawn with no shoulders): tucked inside the
    /// physical notch, exactly notch-sized so it is invisible against it. Without a notch it
    /// collapses to a zero-height sliver at the top edge.
    var hiddenBodySize: CGSize {
        hasNotch
            ? CGSize(width: notchRect.width, height: notchHeight)
            : CGSize(width: notchRect.width * 0.6, height: 0)
    }

    /// Fixed panel frame: top-centered on the notch, big enough for the largest mode + shoulders
    /// + shadow room. The panel never resizes; SwiftUI animates the island inside it.
    var panelFrame: CGRect {
        let w = Self.expandedSize.width + 2 * Self.shoulderRadius + 60
        let h = max(Self.expandedSize.height, Self.readerMaxHeight) + 40
        return CGRect(x: (notchRect.midX - w / 2).rounded(), y: screenFrame.maxY - h, width: w, height: h)
    }

    /// Screen rect of an island with the given body size (shoulders included).
    func islandScreenRect(bodySize: CGSize) -> CGRect {
        let w = bodySize.width + 2 * Self.shoulderRadius
        return CGRect(x: notchRect.midX - w / 2, y: screenFrame.maxY - bodySize.height,
                      width: w, height: bodySize.height)
    }
}

/// Island outline, drawn top-centered in its rect: flat top flush with the screen edge, concave
/// "shoulders" of radius `shoulderRadius` at the top corners (curving outward like the physical
/// notch), straight sides, convex bottom corners of radius `bottomRadius`. Body width/height and
/// both radii are animatable, so a spring between two states interpolates the outline itself
/// (shoulders stay correct at every frame) while the hosting panel never changes size.
/// The outline spans `bodyWidth + 2 * shoulderRadius` horizontally.
struct NotchShape: Shape {
    var bodyWidth: CGFloat
    var bodyHeight: CGFloat
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(bodyWidth, bodyHeight), AnimatablePair(shoulderRadius, bottomRadius)) }
        set {
            bodyWidth = newValue.first.first
            bodyHeight = newValue.first.second
            shoulderRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(0, bodyWidth), h = max(0, bodyHeight)
        guard w > 0.5, h > 0.5 else { return Path() }
        let s = max(0, min(shoulderRadius, w / 4, h / 2))
        let r = max(0, min(bottomRadius, w / 2, h - s))
        let l = rect.midX - w / 2 - s, rt = rect.midX + w / 2 + s
        let t = rect.minY, b = rect.minY + h
        var p = Path()
        p.move(to: CGPoint(x: l, y: t))
        p.addLine(to: CGPoint(x: rt, y: t))
        // Right shoulder: concave quarter circle centered at (rt, t + s).
        p.addArc(tangent1End: CGPoint(x: rt - s, y: t), tangent2End: CGPoint(x: rt - s, y: t + s), radius: s)
        p.addLine(to: CGPoint(x: rt - s, y: b - r))
        // Bottom-right convex corner.
        p.addArc(tangent1End: CGPoint(x: rt - s, y: b), tangent2End: CGPoint(x: rt - s - r, y: b), radius: r)
        p.addLine(to: CGPoint(x: l + s + r, y: b))
        // Bottom-left convex corner.
        p.addArc(tangent1End: CGPoint(x: l + s, y: b), tangent2End: CGPoint(x: l + s, y: b - r), radius: r)
        p.addLine(to: CGPoint(x: l + s, y: t + s))
        // Left shoulder: concave quarter circle centered at (l, t + s).
        p.addArc(tangent1End: CGPoint(x: l + s, y: t), tangent2End: CGPoint(x: l, y: t), radius: s)
        p.closeSubpath()
        return p
    }
}
