import Foundation

// Pure scroll-gesture logic for the reply reader and the quick-reply field (no AppKit; the app
// feeds it from its NSEvent monitor / NSTextView). Self-tested in ScrollGestureTests.swift.

/// Gesture phase of one scroll event, normalised from NSEvent's `phase` / `momentumPhase`
/// (mouse wheels have no phases: the app starts a new gesture after a short pause).
public enum ScrollGesturePhase: Equatable, Sendable {
    case began, changed, ended, momentum
}

/// "Scroll up past the top of the reply to go back to the list."
///
/// Only a gesture that STARTS with the reply already at its top can go back, and only by
/// overscrolling: the upward travel while still at the top must exceed `threshold`. A gesture
/// that moved the content (scrolled down, or wasn't at the top when it began) never goes back,
/// even if it reaches the top later. Momentum (inertial) events never count.
public struct OverscrollBackGesture: Equatable, Sendable {
    public enum Output: Equatable, Sendable {
        /// Nothing to do (the scroll view handles the event).
        case none
        /// Overscrolling at the top: 0…1 of the way to going back (for a visual cue).
        case progress(Double)
        /// Threshold passed: go back to the list (once per gesture).
        case back
    }

    /// Upward travel (points) at the top before going back.
    public var threshold: Double
    /// Downward travel tolerated (finger jitter) before the gesture counts as scrolling the content.
    public var downTolerance: Double

    public private(set) var active = false
    /// The content was at its top when the gesture began.
    public private(set) var atTopAtBegin = false
    /// This gesture can no longer go back (content moved / started below the top / already fired).
    public private(set) var disqualified = true
    public private(set) var overscroll: Double = 0
    public private(set) var downTravel: Double = 0
    public private(set) var fired = false

    public init(threshold: Double = 60, downTolerance: Double = 6) {
        self.threshold = threshold
        self.downTolerance = downTolerance
    }

    /// Feed one event. `deltaUp` > 0 = scrolling up (towards the top; NSEvent.scrollingDeltaY
    /// sign). `atTop` = the content is at (or rubber-banding above) its top before this event
    /// is applied.
    public mutating func handle(_ phase: ScrollGesturePhase, deltaUp: Double, atTop: Bool) -> Output {
        switch phase {
        case .momentum:
            return .none
        case .ended:
            reset()
            return .none
        case .began:
            reset()
            active = true
            atTopAtBegin = atTop
            disqualified = !atTop
        case .changed:
            break
        }
        // A gesture already in progress when we started watching (no .began seen) never counts.
        guard active, !disqualified else { return .none }
        if !atTop { disqualified = true; return .none }    // the content moved away from the top
        if deltaUp < 0 {
            downTravel += -deltaUp
            if downTravel > downTolerance { disqualified = true; overscroll = 0; return .progress(0) }
            return .progress(min(1, overscroll / threshold))
        }
        overscroll += deltaUp
        if overscroll >= threshold {
            fired = true
            disqualified = true
            return .back
        }
        return .progress(min(1, overscroll / threshold))
    }

    public mutating func reset() {
        active = false
        atTopAtBegin = false
        disqualified = true
        overscroll = 0
        downTravel = 0
        fired = false
    }
}

/// Distance of a scroll view's visible top from the content's top, from the clip view's bounds
/// origin (flipped document = y grows downward, as SwiftUI's HostingScrollView) or, unflipped,
/// from the document height. Negative while rubber-banding above the top.
public enum ScrollPosition {
    public static func distanceFromTop(originY: Double, visibleHeight: Double, documentHeight: Double,
                                       flipped: Bool, topInset: Double = 0) -> Double {
        if flipped { return originY + topInset }
        return documentHeight - (originY + visibleHeight)
    }

    public static func distanceFromBottom(originY: Double, visibleHeight: Double, documentHeight: Double,
                                          flipped: Bool, bottomInset: Double = 0) -> Double {
        if flipped { return documentHeight + bottomInset - (originY + visibleHeight) }
        return originY
    }

    /// At (or above) the top, within `tolerance` points.
    public static func isAtTop(distanceFromTop d: Double, tolerance: Double = 2) -> Bool { d <= tolerance }
}

/// Quick-reply field growth: 1 line up to `maxLines`, then it scrolls internally.
public enum ReplyFieldGrowth {
    public static let maxLines = 5

    /// Visible lines for laid-out text of `contentHeight` (one line ≈ `lineHeight`).
    public static func lines(contentHeight: Double, lineHeight: Double, maxLines: Int = maxLines) -> Int {
        guard lineHeight > 0 else { return 1 }
        let n = Int((contentHeight / lineHeight - 0.25).rounded(.up))
        return min(max(n, 1), maxLines)
    }

    /// Height the field adds over its one-line height.
    public static func extraHeight(contentHeight: Double, lineHeight: Double, maxLines: Int = maxLines) -> Double {
        Double(lines(contentHeight: contentHeight, lineHeight: lineHeight, maxLines: maxLines) - 1) * lineHeight
    }

    /// The text is taller than the field may grow: it scrolls inside.
    public static func scrolls(contentHeight: Double, lineHeight: Double, maxLines: Int = maxLines) -> Bool {
        contentHeight > Double(maxLines) * lineHeight + 0.5
    }

    /// Return in the field: plain ↩ (and ⌘↩) sends; ⇧↩ / ⌥↩ / ⌃↩ insert a new line.
    public enum ReturnAction: Equatable, Sendable { case send, newline }

    public static func returnAction(shift: Bool, option: Bool, control: Bool) -> ReturnAction {
        (shift || option || control) ? .newline : .send
    }
}
