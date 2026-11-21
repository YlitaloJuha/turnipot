import Foundation
import NotchCore

/// HotKeyGate: needs-you hot keys arm only after the pointer moved onto the drop-down.
func registerHotKeyGateTests() {
    var g = HotKeyGate()
    check("gate: nothing shown -> off", !g.update(key: nil, pointerX: 0, pointerY: 0, inside: true))
    // Appears under a resting pointer: not armed until it moves.
    check("gate: appeared under the pointer -> not armed", !g.update(key: "permission-A", pointerX: 100, pointerY: 900, inside: true))
    check("gate: pointer still resting -> not armed", !g.update(key: "permission-A", pointerX: 101, pointerY: 900, inside: true))
    check("gate: pointer moved -> armed", g.update(key: "permission-A", pointerX: 106, pointerY: 900, inside: true))
    check("gate: pointer left -> not armed (outside)", !g.update(key: "permission-A", pointerX: 500, pointerY: 500, inside: false))
    check("gate: back inside -> armed", g.update(key: "permission-A", pointerX: 100, pointerY: 900, inside: true))
    // Next request in the queue appears under the same pointer (after ⌘↩ on the first one).
    check("gate: next request under the pointer -> not armed", !g.update(key: "permission-B", pointerX: 100, pointerY: 900, inside: true))
    // Appeared while the pointer was elsewhere: entering it is deliberate.
    var h = HotKeyGate()
    check("gate: appeared away from the pointer", !h.update(key: "permission-C", pointerX: 0, pointerY: 0, inside: false))
    check("gate: entered later -> armed", h.update(key: "permission-C", pointerX: 100, pointerY: 900, inside: true))
    check("gate: dismissed -> off", !h.update(key: nil, pointerX: 100, pointerY: 900, inside: true))
    check("gate: dismissed -> disarmed", !h.isArmed)
}
