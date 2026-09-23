import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global shortcuts via Carbon's `RegisterEventHotKey` — the one keyboard API
/// that needs no Accessibility or Input Monitoring permission, so an ad-hoc
/// signed build can rely on it. (The ⌥⇥ switcher can't use this: it must see
/// the modifier release, which only an event tap delivers.)
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var handler: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]
    private var nextID: UInt32 = 1

    /// Registers `combo`; returns a token for `unregister`, or nil if the
    /// system refused it (typically: the combo is taken by macOS itself).
    @discardableResult
    func register(_ combo: KeyCombo, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), Self.carbonModifiers(combo.flags), hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return nil }
        registrations[id] = (ref, action)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let entry = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    /// Replaces whatever `token` pointed at with `combo` (nil = none).
    func rebind(_ token: inout UInt32?, to combo: KeyCombo?, action: @escaping () -> Void) {
        if let token { unregister(token) }
        token = combo.flatMap { register($0, action: action) }
    }

    nonisolated static let signature: OSType = 0x544D5048  // 'TMPH'

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            // Other handlers (the switcher) share this target; leave theirs alone.
            guard hotKeyID.signature == HotkeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyCenter.shared.fire(hotKeyID.id) }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private func fire(_ id: UInt32) {
        registrations[id]?.action()
    }
}

/// A settings row that records a shortcut: click, press the keys, done.
/// ⎋ cancels, ⌫ clears. Only combos with a modifier (or a function key) are
/// accepted so a plain letter can't hijack typing everywhere.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    var theme: Theme
    @ViewState private var recording = false
    @ViewState private var monitor: Any?
    @ViewState private var rejected = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (combo?.label ?? "Record shortcut"))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospaced()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(minWidth: 110)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(recording ? 0.1 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                recording ? AnyShapeStyle(theme.gradient)
                                    : rejected ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.clear),
                                lineWidth: 1.5
                            )
                    )
                    .foregroundStyle(combo == nil && !recording ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            if combo != nil && !recording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
            if rejected {
                Text("Add a modifier")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil  // swallow: the panel must not act on the keystroke
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        switch event.keyCode {
        case 53:  // ⎋
            stop()
        case 51, 117:  // ⌫ ⌦
            combo = nil
            stop()
        default:
            let candidate = KeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags)
            if candidate.isUsable {
                combo = candidate
                stop()
            } else {
                rejected = true
            }
        }
    }
}
