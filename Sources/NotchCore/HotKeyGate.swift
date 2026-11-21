import Foundation

/// The needs-you drop-downs' hot keys (⌘↩, esc, 1-9) swallow those keys system-wide while armed,
/// and they arm while the pointer is over the island. A drop-down that appears under a pointer
/// that was merely resting at the top of the screen must not turn a ⌘↩ / esc typed in another app
/// into "Allow" / "Deny": the hot keys arm only once the pointer has moved since the drop-down
/// appeared (or entered it from outside).
public struct HotKeyGate: Equatable, Sendable {
    /// Pointer travel (points) that counts as "the user moved onto it".
    public static let minMove: Double = 4

    private var key: String?
    private var originX = 0.0
    private var originY = 0.0
    public private(set) var isArmed = false

    public init() {}

    /// `key` identifies the drop-down on screen (nil = none). Returns true when its hot keys may
    /// arm because of the pointer (armed and the pointer is inside).
    public mutating func update(key: String?, pointerX: Double, pointerY: Double, inside: Bool) -> Bool {
        guard let key else {
            self.key = nil
            isArmed = false
            return false
        }
        if key != self.key {
            self.key = key
            originX = pointerX
            originY = pointerY
            // Appeared away from the pointer: entering it later is a deliberate move.
            isArmed = !inside
        } else if !isArmed, !inside || hypot(pointerX - originX, pointerY - originY) >= Self.minMove {
            isArmed = true
        }
        return isArmed && inside
    }
}
