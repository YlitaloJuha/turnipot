import AppKit
import Carbon.HIToolbox

/// Global hot keys via Carbon RegisterEventHotKey (no Accessibility permission needed).
/// Registered only while a permission prompt is showing and the pointer is over the island
/// (NotchWindowController.updateHotKeys): ⌘↩ = Allow, esc = Deny. For questions: ⌘↩ = next /
/// submit, esc = answer in terminal, 1-9 = pick an option (not while a text field is edited);
/// for plans: ⌘↩ = approve, esc = open session. While registered these combos
/// are consumed system-wide, so they are unregistered as soon as either condition ends.
/// `.escapeOnly` arms just esc (while the pointer is over the "While you were away" drop-down).
@MainActor
final class PermissionHotKeys {
    /// allow = ⌘↩, deny = esc, digit1...digit9 = 1-9 (question options).
    enum Action: UInt32 {
        case allow = 1, deny = 2
        case digit1 = 11, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
        var digit: Int? { rawValue >= 11 && rawValue <= 19 ? Int(rawValue) - 10 : nil }
    }

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private(set) var isRegistered = false
    /// permission / plan: ⌘↩ + esc; question: also 1-9; escapeOnly: esc.
    enum Mode: Equatable { case off, permission, question, escapeOnly }
    private(set) var mode: Mode = .off
    var onAction: ((Action) -> Void)?

    /// Carbon callback has no context capture; route through a static.
    nonisolated(unsafe) fileprivate static weak var current: PermissionHotKeys?

    func setEnabled(_ enabled: Bool) { setMode(enabled ? .permission : .off) }

    func setMode(_ newMode: Mode) {
        if newMode == mode { return }
        if isRegistered { unregister() }
        mode = newMode
        if newMode != .off { register(escapeOnly: newMode == .escapeOnly, digits: newMode == .question) }
    }

    /// Virtual key codes of the number row 1-9 (not contiguous).
    private static let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                           kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    private func register(escapeOnly: Bool, digits: Bool = false) {
        Self.current = self
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, &handlerRef)
            if status != noErr { NSLog("Turnipot: InstallEventHandler failed \(status)"); return }
        }
        let signature: OSType = 0x434E_4F54   // 'CNOT'
        var keys: [(UInt32, UInt32, Action)] = [(UInt32(kVK_Escape), 0, .deny)]
        if !escapeOnly {
            keys += [(UInt32(kVK_Return), UInt32(cmdKey), .allow), (UInt32(kVK_ANSI_KeypadEnter), UInt32(cmdKey), .allow)]
        }
        if digits {
            for (i, code) in Self.digitKeys.enumerated() {
                if let a = Action(rawValue: UInt32(11 + i)) { keys.append((UInt32(code), 0, a)) }
            }
        }
        for (code, mods, action) in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.rawValue)
            let status = RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
            else { NSLog("Turnipot: RegisterEventHotKey(\(code)) failed \(status)") }
        }
        isRegistered = true
    }

    private func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        isRegistered = false
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = Action(rawValue: id) else { return }
        onAction?(action)
    }
}

private func hotKeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hk = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
    guard status == noErr else { return status }
    let id = hk.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { PermissionHotKeys.current?.fire(id) }
    }
    return noErr
}
