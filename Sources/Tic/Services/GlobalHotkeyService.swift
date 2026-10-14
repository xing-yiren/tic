import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
///
/// Carbon's `RegisterEventHotKey` is used deliberately — it needs **no** Accessibility permission
/// (unlike an `NSEvent` global monitor or `CGEventTap`), the whole reason the plan asks to prefer the
/// system hotkey path over an accessibility listener.
struct HotkeyShortcut: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// ⌘⇧N — the plan's suggested initial candidate.
    static let `default` = HotkeyShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    /// A bare key (no command/option/control/shift) would swallow ordinary typing system-wide, so we
    /// require at least one real modifier before a shortcut is considered valid.
    var isValid: Bool { carbonModifiers != 0 }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Builds a shortcut from an AppKit key event's key code + flags (used when the recorder captures
    /// a chord). Returns nil when no supported modifier is held.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        guard carbon != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
    }

    /// A human-readable form like "⇧⌘N" for menus and the settings window.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    private static func keyName(for keyCode: UInt32) -> String {
        // A small map of the keys people actually bind; anything else falls back to the layout.
        let special: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        if let name = special[Int(keyCode)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "key \(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
        }
        guard status == noErr, length > 0 else { return "key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Registers a single system-wide hotkey via Carbon and routes it to a handler. Reports a conflict
/// (another app already owns the chord) instead of silently doing nothing.
@MainActor
final class GlobalHotkeyService {
    enum RegistrationResult: Equatable {
        case registered
        case conflict          // the chord is taken by another app / another hotkey
        case invalid           // no modifier, or a bad key
        case failed            // any other Carbon error
    }

    private static let signature: OSType = 0x5449_4331   // 'TIC1'

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    /// Registers `shortcut`, replacing any previous registration. On failure the previous hotkey is
    /// left unregistered and the caller gets a result it can surface.
    @discardableResult
    func register(_ shortcut: HotkeyShortcut, handler: @escaping () -> Void) -> RegistrationResult {
        unregister()
        guard shortcut.isValid else { return .invalid }
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let service = Unmanaged<GlobalHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { service.fire() }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard installStatus == noErr else {
            self.handler = nil
            return .failed
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr else {
            // -9878 eventHotKeyExistsErr: the chord is already owned elsewhere.
            removeEventHandler()
            self.handler = nil
            return registerStatus == OSStatus(eventHotKeyExistsErr) ? .conflict : .failed
        }
        return .registered
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        removeEventHandler()
        handler = nil
    }

    private func removeEventHandler() {
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    fileprivate func fire() { handler?() }
}
