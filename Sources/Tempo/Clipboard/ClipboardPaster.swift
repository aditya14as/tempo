import AppKit
import Carbon.HIToolbox

/// Pastes into whatever app is in front by posting ⌘V, the way Maccy does.
///
/// Needs Accessibility (macOS drops synthetic keys from apps without it).
/// Call it only once the popup is gone and the previous app is key again —
/// `ClipboardHistory.paste` waits ~60 ms for that.
enum ClipboardPaster {
    @MainActor
    static func pasteIntoFrontApp() {
        guard Permissions.accessibilityGranted else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys the user is still holding (the popup's ⌥ or ⇧) mustn't turn
        // ⌘V into ⌥⌘V; suppress local keyboard events for the brief moment.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let key = vKeyCode()
        // 0x000008 is the left-⌘ device bit; some apps check for it.
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// The key that types "v" with ⌘ held in the current keyboard layout (on
    /// Dvorak that's not the QWERTY V key; "Dvorak – QWERTY ⌘" maps ⌘ back
    /// to QWERTY, which asking with ⌘ held gets right). Layouts with no "v"
    /// at all (Cyrillic, Greek…) use the ANSI V key, as macOS itself does.
    /// Some layouts (old KCHR-only ones) carry no Unicode key data; then the
    /// ASCII-capable layout macOS falls back to for ⌘ shortcuts is asked.
    static func vKeyCode() -> CGKeyCode {
        func layoutData(_ source: TISInputSource?) -> Data? {
            guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return nil }
            // Copied: the data belongs to `source`, which is released after.
            let cf = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            return withExtendedLifetime(source) { Data(bytes: CFDataGetBytePtr(cf), count: CFDataGetLength(cf)) }
        }
        guard let data = layoutData(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
            ?? layoutData(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
        else { return CGKeyCode(kVK_ANSI_V) }
        let modifiers = UInt32((cmdKey >> 8) & 0xFF)
        let found: CGKeyCode? = data.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<UInt16(128) {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(("v" as Unicode.Scalar).value) {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
        return found ?? CGKeyCode(kVK_ANSI_V)
    }
}
