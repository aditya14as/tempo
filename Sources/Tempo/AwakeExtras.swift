import AppKit
import CoreLocation
import CoreWLAN
import IOKit
import IOKit.usb

// MARK: - Closed-lid mode

/// Keeps a MacBook running with the lid shut and no external display.
///
/// Power assertions can't do this — closing the lid sleeps the Mac regardless.
/// The only switch is `pmset -a disablesleep 1`, which needs root. Tempo asks
/// for an admin password once to install a sudo rule that allows exactly two
/// commands (`pmset -a disablesleep 1` and `… 0`) and nothing else; after
/// that it flips the switch silently.
///
/// "Stuck on" is the danger (a Mac that never sleeps in a bag), so three
/// things turn it back off: the session ending, Tempo quitting, and — if
/// Tempo crashes or is force-quit — a tiny watchdog shell that waits for
/// Tempo's process to disappear and then runs the "off" command itself.
@MainActor
final class ClosedLid: ObservableObject {
    static let shared = ClosedLid()

    static let sudoersPath = "/etc/sudoers.d/tempo-closed-lid"
    nonisolated private static let pmset = "/usr/bin/pmset"
    private static let markerKey = "tempo.closedLid.active"

    @Published private(set) var installed = FileManager.default.fileExists(atPath: ClosedLid.sudoersPath)
    @Published private(set) var active = false
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false
    private var watchdog: Process?

    /// Only laptops have a lid (the root power domain reports its state).
    static let hasLid: Bool = clamshellState() != nil

    static var lidClosed: Bool { clamshellState() == true }

    private static func clamshellState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Bool
    }

    /// The one line Tempo adds to sudoers. Pure, so `--check` can vet it.
    nonisolated static func sudoersLine(user: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, user.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 1, \(pmset) -a disablesleep 0"
    }

    /// After a crash the watchdog has already reset sleep; this covers the
    /// rare case where it couldn't (e.g. the rule was removed meanwhile).
    func recoverAtLaunch() {
        installed = FileManager.default.fileExists(atPath: Self.sudoersPath)
        if UserDefaults.standard.bool(forKey: Self.markerKey) {
            run(disable: false, wait: true)
            UserDefaults.standard.set(false, forKey: Self.markerKey)
        }
    }

    /// Brings `pmset disablesleep` in line with what the engine wants.
    func set(_ on: Bool) {
        let want = on && installed
        guard want != active else { return }
        active = want
        UserDefaults.standard.set(want, forKey: Self.markerKey)
        if want {
            run(disable: true, wait: false)
            startWatchdog()
        } else {
            stopWatchdog()
            run(disable: false, wait: false)
        }
    }

    /// Quitting: switch it off before the process goes away.
    func shutdown() {
        guard active else { return }
        active = false
        stopWatchdog()
        run(disable: false, wait: true)
        UserDefaults.standard.set(false, forKey: Self.markerKey)
    }

    private func run(disable: Bool, wait: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", Self.pmset, "-a", "disablesleep", disable ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            if wait { process.waitUntilExit() }
        } catch {
            lastError = "Couldn't run pmset: \(error.localizedDescription)"
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let pid = getpid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 2; done; /usr/bin/sudo -n \(Self.pmset) -a disablesleep 0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        watchdog = process
    }

    private func stopWatchdog() {
        if let watchdog, watchdog.isRunning { watchdog.terminate() }
        watchdog = nil
    }

    // MARK: Setup (one admin prompt)

    /// Installs the sudo rule behind the standard macOS admin password dialog.
    func install() {
        guard let line = Self.sudoersLine(user: NSUserName()) else {
            lastError = "Your account name has characters sudo can't take."
            return
        }
        // Written into a root-owned temp file, syntax-checked by visudo, and
        // only then moved into place — a bad rule can never lock sudo up.
        let script = [
            "set -e",
            "/usr/bin/grep -q '^#includedir /private/etc/sudoers.d' /etc/sudoers",
            "tmp=$(/usr/bin/mktemp /private/tmp/tempo-sudoers.XXXXXX)",
            "/bin/echo '\(line)' > \"$tmp\"",
            "/usr/sbin/visudo -cf \"$tmp\" >/dev/null",
            "/usr/sbin/chown root:wheel \"$tmp\"",
            "/bin/chmod 0440 \"$tmp\"",
            "/bin/mv \"$tmp\" \(Self.sudoersPath)",
        ].joined(separator: "; ")
        runPrivileged(script, prompt: "Tempo wants to keep your Mac awake with the lid closed.") { ok in
            self.installed = FileManager.default.fileExists(atPath: Self.sudoersPath)
            if ok && !self.installed { self.lastError = "The rule didn't install." }
            AwakeEngine.shared.refresh()
        }
    }

    /// Removes the rule (and makes sure sleep is back on first).
    func uninstall() {
        shutdown()
        let script = "/usr/bin/pmset -a disablesleep 0; /bin/rm -f \(Self.sudoersPath)"
        runPrivileged(script, prompt: "Tempo wants to remove its closed-lid permission.") { _ in
            self.installed = FileManager.default.fileExists(atPath: Self.sudoersPath)
            AwakeEngine.shared.refresh()
        }
    }

    private func runPrivileged(_ script: String, prompt: String, done: @escaping @MainActor (Bool) -> Void) {
        busy = true
        lastError = nil
        // The script holds no double quotes or backslashes of its own except
        // the quoted "$tmp"; escape them for the AppleScript string literal.
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            var ok = false
            var message: String?
            do {
                try process.run()
                process.waitUntilExit()
                ok = process.terminationStatus == 0
                if !ok {
                    let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    message = text.contains("-128") ? nil : "Setup failed. \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.lastError = message
                    done(ok)
                }
            }
        }
    }
}

// MARK: - Drive Alive

/// Keeps external drives from spinning down by writing a tiny hidden file
/// to each one every minute while a session runs (Amphetamine's Drive Alive).
@MainActor
final class DriveKeeper {
    static let shared = DriveKeeper()
    nonisolated static let fileName = ".tempo-drive-alive"
    static let interval: TimeInterval = 60

    private var lastWrite: Date = .distantPast
    private var touched: Set<String> = []

    /// Mounted, writable drives that aren't the internal disk.
    static func externalVolumes() -> [DriveRef] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
                                      .volumeUUIDStringKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                v.volumeIsRootFileSystem != true, v.volumeIsInternal != true,
                v.volumeIsReadOnly != true, v.volumeIsBrowsable != false,
                url.path.hasPrefix("/Volumes/")
            else { return nil }
            return DriveRef(id: v.volumeUUIDString ?? url.path, name: v.volumeName ?? url.lastPathComponent,
                            path: url.path)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Which mounted drives the setting covers right now.
    nonisolated static func targets(_ config: AwakeConfig, mounted: [DriveRef]) -> [DriveRef] {
        guard config.driveAlive else { return [] }
        if config.drives.isEmpty { return mounted }
        let chosen = Set(config.drives.map(\.id))
        return mounted.filter { chosen.contains($0.id) }
    }

    func tick(active: Bool, config: AwakeConfig, now: Date = Date()) {
        guard active, config.driveAlive else {
            cleanUp()
            return
        }
        guard now.timeIntervalSince(lastWrite) >= Self.interval else { return }
        lastWrite = now
        let paths = Self.targets(config, mounted: Self.externalVolumes()).map(\.path)
        touched.formUnion(paths)
        let stamp = Data(ISO8601DateFormatter().string(from: now).utf8)
        // A sleeping drive can take seconds to answer; never block the UI on it.
        DispatchQueue.global(qos: .utility).async {
            for path in paths {
                let url = URL(fileURLWithPath: path).appendingPathComponent(Self.fileName)
                try? stamp.write(to: url)
                if let handle = try? FileHandle(forWritingTo: url) {
                    try? handle.synchronize()
                    try? handle.close()
                }
            }
        }
    }

    /// Leaves no trace once the session is over.
    func cleanUp() {
        lastWrite = .distantPast
        guard !touched.isEmpty else { return }
        let paths = touched
        touched.removeAll()
        DispatchQueue.global(qos: .utility).async {
            for path in paths {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent(Self.fileName))
            }
        }
    }
}

// MARK: - Cursor nudge

/// Moves the pointer by a pixel and straight back once you've been idle for
/// a while, so Slack/Teams/Zoom keep showing you as active.
///
/// It tracks *real* idle time itself: the system's idle clock resets on our
/// own nudges too, and Tempo's screen-saver timer must not be fooled by them.
@MainActor
final class CursorNudger {
    static let shared = CursorNudger()

    private var lastNudge: Date = .distantPast
    private var lastRealInput = Date()

    /// Seconds since the last input that wasn't one of our nudges.
    func realIdle(now: Date = Date()) -> TimeInterval {
        let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                   eventType: CGEventType(rawValue: ~0)!)
        lastRealInput = Self.lastRealInput(eventAt: now.addingTimeInterval(-systemIdle), lastNudge: lastNudge,
                                           previous: lastRealInput)
        return now.timeIntervalSince(lastRealInput)
    }

    /// Pure: an input within a second of our nudge is the nudge itself.
    nonisolated static func lastRealInput(eventAt: Date, lastNudge: Date, previous: Date) -> Date {
        if abs(eventAt.timeIntervalSince(lastNudge)) < 1 { return previous }
        return max(previous, eventAt)
    }

    /// Pure: nudge once per interval of idleness, starting when idle reaches it.
    nonisolated static func shouldNudge(realIdle: TimeInterval, sinceLastNudge: TimeInterval, interval: TimeInterval) -> Bool {
        realIdle >= interval && sinceLastNudge >= interval
    }

    func tick(active: Bool, config: AwakeConfig, now: Date = Date()) {
        let idle = realIdle(now: now)
        guard active, config.moveCursor, AXIsProcessTrusted() else { return }
        let interval = TimeInterval(max(1, config.moveCursorMinutes)) * 60
        guard Self.shouldNudge(realIdle: idle, sinceLastNudge: now.timeIntervalSince(lastNudge), interval: interval),
            !Self.wouldDisturb()
        else { return }
        lastNudge = now
        Self.nudge()
    }

    /// A mouse event would wake a sleeping display, dismiss the screen saver
    /// or light up the lock screen — none of which a nudge should ever do.
    private static func wouldDisturb() -> Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            session["CGSSessionScreenIsLocked"] as? Bool == true {
            return true
        }
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.ScreenSaver.Engine" || $0.bundleIdentifier == "com.apple.loginwindow" && $0.isActive
        }
    }

    private static func nudge() {
        guard let here = CGEvent(source: nil)?.location else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        for point in [CGPoint(x: here.x + 1, y: here.y), here] {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Wi-Fi

/// The current Wi-Fi network's name. macOS hides it from apps that don't
/// have Location access, so the Wi-Fi trigger asks for that once.
@MainActor
final class WiFiWatcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WiFiWatcher()

    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var authorized: Bool { status == .authorizedAlways || status == .authorized }
    var denied: Bool { status == .denied || status == .restricted }

    func requestAccess() {
        manager.requestWhenInUseAuthorization()
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    /// nil when not on Wi-Fi, or when the name is hidden from Tempo.
    func currentSSID() -> String? {
        guard let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty else { return nil }
        return ssid
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                WiFiWatcher.shared.status = status
                AwakeEngine.shared.refresh()
            }
        }
    }
}

// MARK: - USB

enum USBDevices {
    /// Plugged-in USB devices (hubs left out), one entry per model.
    static func connected() -> [USBDeviceRef] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var seen = Set<String>()
        var devices: [USBDeviceRef] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let vendor = property("idVendor") as? Int, let product = property("idProduct") as? Int else { continue }
            if property("bDeviceClass") as? Int == 9 { continue }  // hubs
            let name = (property("USB Product Name") as? String)
                ?? (property("kUSBProductString") as? String)
                ?? String(format: "USB device %04X:%04X", vendor, product)
            let device = USBDeviceRef(vendorID: vendor, productID: product, name: name)
            if seen.insert(device.id).inserted { devices.append(device) }
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
