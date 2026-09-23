import AppKit
import Carbon.HIToolbox

/// Catches hold+⇥ (and hold+`) with an event tap on its own thread.
///
/// macOS drops a Carbon hot key now and then (the press lands in the front
/// app instead), so once Accessibility is allowed the switcher is started
/// from here. The tap only decides "is this the shortcut?" and hands the
/// rest to the main thread, so typing never waits on Tempo's main thread.
final class SwitcherTrigger: @unchecked Sendable {
    static let shared = SwitcherTrigger()

    private let lock = NSLock()
    private var enabled = false
    private var modifier: CGEventFlags = .maskAlternate
    private var appWindowsKey = true
    /// A session is open: its own tap handles every key until it ends.
    private var active = false
    private var port: CFMachPort?
    private var started = false

    /// Starts the tap thread once; returns false if the tap couldn't be made
    /// (no Accessibility yet).
    @discardableResult
    func start() -> Bool {
        lock.lock()
        if started { lock.unlock(); return port != nil }
        started = true
        lock.unlock()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, _ in
                    SwitcherTrigger.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: nil
            )
            lock.lock()
            port = tap
            lock.unlock()
            ready.signal()
            guard let tap else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Tempo switcher trigger"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        lock.lock()
        defer { lock.unlock() }
        if port == nil { started = false }
        return port != nil
    }

    func configure(enabled: Bool, modifier: HoldModifier, appWindowsKey: Bool) {
        lock.lock()
        self.enabled = enabled
        self.modifier = modifier.cgFlag
        self.appWindowsKey = appWindowsKey
        lock.unlock()
    }

    func setActive(_ active: Bool) {
        lock.lock()
        self.active = active
        lock.unlock()
    }

    /// Returns true to swallow the event. Runs on the tap thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = port
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type == .keyDown else { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == kVK_Tab || code == kVK_ANSI_Grave else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard enabled, !active else { return false }
        let held = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard held == modifier else { return false }
        let appOnly = code == kVK_ANSI_Grave
        if appOnly && !appWindowsKey { return false }
        active = true
        let caught = CACurrentMediaTime()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SwitcherController.shared.triggered(appOnly: appOnly, latency: CACurrentMediaTime() - caught)
            }
        }
        return true
    }
}

extension HoldModifier {
    var cgFlag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        }
    }
}
