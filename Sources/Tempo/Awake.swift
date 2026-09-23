import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
@preconcurrency import UserNotifications

// MARK: - Pure planning (covered by --check)

/// What the machine looks like right now, as far as triggers care.
struct AwakeEnvironment: Equatable {
    var onAC = true
    var hasBattery = false
    var batteryPercent: Int? = nil
    var externalDisplay = false
    var runningBundleIDs: Set<String> = []
    /// The Wi-Fi network's name, when Tempo may see it.
    var wifiSSID: String? = nil
    /// "vendor:product" IDs of plugged-in USB devices.
    var usbDeviceIDs: Set<String> = []
}

enum AwakePlanner {
    /// A timed session's end, `minutes` from `now`.
    static func end(afterMinutes minutes: Int, from now: Date) -> Date {
        now.addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
    }

    /// When today's work ends, if it hasn't already (drives the "Until 18:00" chip).
    static func workEnd(on now: Date, schedule: WorkSchedule, cal: Calendar = .current) -> Date? {
        let day = schedule.day(cal.component(.weekday, from: now))
        guard day.enabled, day.seconds > 0 else { return nil }
        let end = cal.date(bySettingHour: day.endMinute / 60, minute: day.endMinute % 60, second: 0,
                           of: cal.startOfDay(for: now))
        guard let end, end > now else { return nil }
        return end
    }

    /// True while `now` falls inside one of today's work slots.
    static func inWorkHours(_ now: Date, schedule: WorkSchedule, cal: Calendar = .current) -> Bool {
        let day = schedule.day(cal.component(.weekday, from: now))
        guard day.enabled else { return false }
        let c = cal.dateComponents([.hour, .minute], from: now)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return day.slots.contains { minute >= $0.startMinute && minute < $0.endMinute }
    }

    /// The first satisfied trigger, as a human reason ("External display"), or nil.
    static func triggerReason(
        _ triggers: AwakeTriggers, env: AwakeEnvironment, now: Date, schedule: WorkSchedule,
        cal: Calendar = .current
    ) -> String? {
        guard triggers.enabled else { return nil }
        if let app = triggers.apps.first(where: { env.runningBundleIDs.contains($0.bundleID) }) {
            return "\(app.name) is open"
        }
        if let device = triggers.usbDevices.first(where: { env.usbDeviceIDs.contains($0.id) }) {
            return "\(device.name) connected"
        }
        if let ssid = env.wifiSSID, triggers.wifiNetworks.contains(ssid) { return "On \(ssid) Wi-Fi" }
        if triggers.externalDisplay && env.externalDisplay { return "External display connected" }
        if triggers.onPower && env.hasBattery && env.onAC { return "Plugged in" }
        if triggers.workHours && inWorkHours(now, schedule: schedule, cal: cal) { return "Work hours" }
        return nil
    }

    /// Why the battery guard forbids staying awake, or nil when it's fine.
    static func batteryStop(_ config: AwakeConfig, env: AwakeEnvironment) -> String? {
        guard env.hasBattery, !env.onAC else { return nil }
        if config.endWhenUnplugged { return "Unplugged from power" }
        if config.endOnLowBattery, let pct = env.batteryPercent, pct < config.lowBatteryPercent {
            return "Battery below \(config.lowBatteryPercent)%"
        }
        return nil
    }

    /// "2h 05m", "42m", "35s", "2d 3h".
    static func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s < 60 { return "\(s)s" }
        let minutes = (s + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        if minutes >= 24 * 60 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// Compact menu bar form: "42m", "2h05", "2d3h".
    static func menuBarRemaining(_ seconds: TimeInterval) -> String {
        let minutes = max(0, (Int(seconds.rounded(.up)) + 59) / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes >= 24 * 60 { return "\(minutes / 1440)d\(minutes % 1440 / 60)h" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    /// When a session ends, as briefly as is unambiguous:
    /// "18:00", "tomorrow 09:00", "Fri 25 Sep 09:00".
    static func untilLabel(_ end: Date, now: Date, cal: Calendar = .current, locale: Locale = .current) -> String {
        let time = clock(end, cal: cal, locale: locale)
        if cal.isDate(end, inSameDayAs: now) { return time }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(end, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return "\(formatter.string(from: end)) \(time)"
    }

    /// Merges a picked day and a picked time of day into one moment.
    static func combine(day: Date, time: Date, cal: Calendar = .current) -> Date {
        var c = cal.dateComponents([.year, .month, .day], from: day)
        let t = cal.dateComponents([.hour, .minute], from: time)
        c.hour = t.hour
        c.minute = t.minute
        c.second = 0
        return cal.date(from: c) ?? day
    }

    /// "30m", "1h", "1h 30m" for preset chips.
    static func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// A time of day in the user's 12- or 24-hour style: "18:00" / "6:00 PM".
    static func clock(_ date: Date, cal: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    /// The next occurrence of a wall-clock time: today if still ahead, else tomorrow.
    static func nextOccurrence(ofTimeIn picked: Date, after now: Date, cal: Calendar = .current) -> Date {
        let t = cal.dateComponents([.hour, .minute], from: picked)
        let today = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0, of: now) ?? now
        return today > now ? today : (cal.date(byAdding: .day, value: 1, to: today) ?? today)
    }
}

// MARK: - The live state the UI renders

struct AwakeState: Equatable {
    enum Source: Equatable {
        case manual(AwakeSession)
        case trigger(String)
    }
    var source: Source
    var displayOn: Bool

    var session: AwakeSession? {
        if case .manual(let s) = source { return s }
        return nil
    }
    var endsAt: Date? { session?.endsAt }
    var isTrigger: Bool {
        if case .trigger = source { return true }
        return false
    }
}

// MARK: - Engine

/// Keeps the Mac awake with IOKit power assertions — the same two Amphetamine
/// holds ("PreventUserIdleSystemSleep", plus "PreventUserIdleDisplaySleep"
/// unless the display may sleep). Exactly one pair is held at a time, for
/// whichever of a manual session or a satisfied trigger is in charge.
@MainActor
final class AwakeEngine: ObservableObject {
    static let shared = AwakeEngine()

    @Published private(set) var state: AwakeState?
    @Published private(set) var env = AwakeEnvironment()
    /// Why the last session ended ("Timer finished"), shown briefly in the tab.
    @Published private(set) var lastEndReason: String?

    private weak var store: ConfigStore?
    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var hotkeyToken: UInt32?
    private var boundShortcut: KeyCombo?
    private var warnedFor: Date?
    private var screenSaverFiredForIdle = false
    private var observers: [NSObjectProtocol] = []
    private var configObservation: Any?
    private var lastRefresh = Date.distantPast
    /// When the trigger in charge stopped holding. Displays, USB and Wi-Fi
    /// drop out for a moment on wake; wait before letting the Mac sleep.
    private var triggerLostAt: Date?
    /// The trigger rules at the last refresh: the grace is for the world
    /// changing under a rule, not for the user pausing or editing rules.
    private var lastTriggers: AwakeTriggers?
    private var didShutDown = false
    private static let triggerGrace: TimeInterval = 30
    /// Low battery stopped the triggers; they resume a little above the line.
    private var batteryBlocked = false
    /// Keeps App Nap from stretching the 1 s tick while Tempo holds the Mac awake.
    private var noNap: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: Lifecycle

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        self.store = store
        ClosedLid.shared.recoverAtLaunch()
        refreshEnvironment()

        // A session saved before quitting resumes — unless it has already run out.
        if let saved = store.config.awake.session {
            if let end = saved.endsAt, end <= Date() {
                store.config.awake.session = nil
            } else if let app = saved.app, !env.runningBundleIDs.contains(app.bundleID) {
                store.config.awake.session = nil
            }
        }
        if store.config.awake.session == nil, store.config.awake.startAtLaunch {
            store.config.awake.session = AwakeSession(kind: .indefinite)
        }
        if let resumed = store.config.awake.session {
            // Already inside the warning window before the relaunch: it was sent then.
            if let end = resumed.endsAt, end.timeIntervalSinceNow <= TimeInterval(store.config.awake.warnBeforeEndMinutes) * 60 {
                warnedFor = end
            }
            prepareNotifications(for: resumed)
        }
        installSignalHandlers()
        DriveKeeper.shared.watchVolumes()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AwakeEngine.shared.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AwakeEngine.shared.refresh() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AwakeEngine.shared.shutDown() } })

        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AwakeEngine.shared.refresh() } }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        configObservation = store.$config
            .map { ($0.features.awake, $0.awake) }
            .removeDuplicates(by: ==)
            .sink { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { AwakeEngine.shared.refresh() } }
            }

        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { AwakeEngine.shared.tick() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    // MARK: Actions

    /// Starts (or replaces) a manual session.
    func begin(_ kind: AwakeSessionKind) {
        guard let store, store.config.features.awake else { return }
        refreshEnvironment()
        // Refuse a session that would end on the spot, quietly: no chime,
        // no "session ended" notification.
        if case .until(let end) = kind, end <= Date() {
            lastEndReason = "That time has already passed"
            return
        }
        if let stop = AwakePlanner.batteryStop(store.config.awake, env: env) {
            lastEndReason = stop
            return
        }
        lastEndReason = nil
        warnedFor = nil
        let session = AwakeSession(kind: kind, allowDisplaySleep: store.config.awake.allowDisplaySleep)
        store.config.awake.session = session
        prepareNotifications(for: session)
        if store.config.awake.sounds { NSSound(named: "Tink")?.play() }
        refresh()
    }

    func begin(minutes: Int) {
        begin(minutes <= 0 ? .indefinite : .until(AwakePlanner.end(afterMinutes: minutes, from: Date())))
    }

    /// Adds time to a running timed session (or makes an indefinite one timed from now).
    func extend(minutes: Int) {
        // Only timed sessions: extending "forever" or "while an app runs" would shorten it.
        guard let store, var session = store.config.awake.session, session.endsAt != nil else { return }
        let base = max(session.endsAt ?? Date(), Date())
        session.kind = .until(base.addingTimeInterval(TimeInterval(minutes) * 60))
        store.config.awake.session = session
        warnedFor = nil
    }

    func stop() {
        end(reason: nil)
    }

    /// The shortcut: stop if a manual session runs, else start the default one.
    func toggle() {
        guard let store else { return }
        if store.config.awake.session != nil {
            stop()
        } else {
            begin(minutes: store.config.awake.defaultMinutes)
        }
    }

    // MARK: Internals

    private func end(reason: String?) {
        guard let store, store.config.awake.session != nil else { return }
        store.config.awake.session = nil
        lastEndReason = reason
        let awake = store.config.awake
        if awake.sounds { NSSound(named: "Pop")?.play() }
        if let reason, awake.notifyOnEnd {
            // A trigger may take over the moment the session ends; say so.
            let takesOver = AwakePlanner.batteryStop(awake, env: env) == nil
                ? AwakePlanner.triggerReason(awake.triggers, env: env, now: Date(), schedule: store.config.schedule)
                : nil
            if let takesOver {
                AwakeNotifier.post(title: "Keep-awake session ended", body: "\(reason). Still awake: \(takesOver).")
            } else {
                AwakeNotifier.post(title: "Your Mac can sleep again", body: reason)
            }
        }
        refresh()
    }

    private func tick() {
        guard let store else { return }
        let now = Date()
        let awake = store.config.awake
        if let session = awake.session, let endsAt = session.endsAt {
            if endsAt <= now {
                end(reason: "The timer finished")
                return
            }
            let warn = TimeInterval(awake.warnBeforeEndMinutes) * 60
            if warn > 0, endsAt.timeIntervalSince(now) <= warn, warnedFor != endsAt,
                endsAt.timeIntervalSince(session.startedAt) > warn {
                warnedFor = endsAt
                AwakeNotifier.post(
                    title: "Staying awake for \(AwakePlanner.remaining(endsAt.timeIntervalSince(now))) more",
                    body: "Open Tempo to add time."
                )
            }
        }
        // Power and triggers change rarely; the rest of the time a cheap poll
        // every few seconds catches schedule edges and battery drain.
        if now.timeIntervalSince(lastRefresh) >= 5 { refresh() }
        let running = state != nil
        CursorNudger.shared.tick(active: running, config: awake, now: now)
        DriveKeeper.shared.tick(active: running, config: awake, now: now)
        maybeStartScreenSaver(awake: awake)
    }

    /// Re-reads the environment and brings the assertions in line with it.
    func refresh() {
        lastRefresh = Date()
        guard let store else { return }
        guard store.config.features.awake else {
            // Feature switched off: nothing may keep the Mac up.
            if store.config.awake.session != nil { store.config.awake.session = nil }
            apply(nil)
            return
        }
        refreshEnvironment()
        let awake = store.config.awake
        let now = Date()

        if var session = awake.session {
            if let app = session.app, !env.runningBundleIDs.contains(app.bundleID) {
                end(reason: "\(app.name) quit")
                return
            }
            if let stop = AwakePlanner.batteryStop(awake, env: env) {
                end(reason: stop)
                return
            }
            if let endsAt = session.endsAt, endsAt <= now {
                end(reason: "The timer finished")
                return
            }
            session.allowDisplaySleep = awake.allowDisplaySleep
            apply(AwakeState(source: .manual(session), displayOn: !awake.allowDisplaySleep))
            return
        }

        let rulesChanged = lastTriggers != awake.triggers
        lastTriggers = awake.triggers
        if let stop = AwakePlanner.batteryStop(awake, env: env) {
            batteryBlocked = stop.hasPrefix("Battery below")
            triggerLostAt = nil
            apply(nil)
            return
        }
        if batteryBlocked, !awake.endOnLowBattery { batteryBlocked = false }
        if batteryBlocked {
            // Resume only a couple of percent above the line, so a reading
            // hovering at it doesn't flap the Mac between awake and not.
            if env.hasBattery, !env.onAC, let pct = env.batteryPercent, pct < awake.lowBatteryPercent + 2 {
                apply(nil)
                return
            }
            batteryBlocked = false
        }
        if let reason = AwakePlanner.triggerReason(awake.triggers, env: env, now: now, schedule: store.config.schedule) {
            triggerLostAt = nil
            apply(AwakeState(source: .trigger(reason), displayOn: !awake.allowDisplaySleep))
        } else if let current = state, current.isTrigger, awake.triggers.enabled, !rulesChanged {
            let lost = triggerLostAt ?? now
            triggerLostAt = lost
            apply(now.timeIntervalSince(lost) < Self.triggerGrace ? current : nil)
        } else {
            apply(nil)
        }
    }

    private func rebindShortcut(_ combo: KeyCombo?) {
        guard combo != boundShortcut else { return }
        boundShortcut = combo
        HotkeyCenter.shared.rebind(&hotkeyToken, to: combo) {
            MainActor.assumeIsolated { AwakeEngine.shared.toggle() }
        }
    }

    private func apply(_ newState: AwakeState?) {
        if newState != state { state = newState }
        if let newState {
            let name = newState.isTrigger ? "Tempo (Auto)" : "Tempo (Keep awake)"
            if systemAssertion == 0 {
                systemAssertion = Self.create(kIOPMAssertPreventUserIdleSystemSleep, "\(name): system")
            }
            if newState.displayOn {
                if displayAssertion == 0 {
                    displayAssertion = Self.create(kIOPMAssertPreventUserIdleDisplaySleep, "\(name): display")
                }
            } else {
                Self.release(&displayAssertion)
            }
        } else {
            releaseAssertions()
        }
        let awake = store?.config.awake
        // Closed-lid mode is for sessions you start, never for automatic
        // triggers: a bagged MacBook in work hours must still sleep.
        ClosedLid.shared.set(newState?.isTrigger == false && awake?.closedLid == true)
        if newState != nil, noNap == nil {
            noNap = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                          reason: "Keeping the Mac awake on schedule")
        } else if newState == nil, let activity = noNap {
            ProcessInfo.processInfo.endActivity(activity)
            noNap = nil
        }
        if newState == nil { DriveKeeper.shared.cleanUp() }
        rebindShortcut(store?.config.features.awake == true ? awake?.toggleShortcut : nil)
    }

    /// Ask for notifications the first time a session could actually send one.
    private func prepareNotifications(for session: AwakeSession) {
        guard let awake = store?.config.awake else { return }
        if awake.notifyOnEnd || (awake.warnBeforeEndMinutes > 0 && session.endsAt != nil) { AwakeNotifier.prepare() }
    }

    /// Ctrl-C, a closed Terminal or `kill` skip willTerminate; clean up for them too.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                // If the main thread is stuck, still go (after a grace for the cleanup).
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(1) }
                MainActor.assumeIsolated {
                    AwakeEngine.shared.shutDown()
                    SwitcherController.shared.restoreSystemShortcuts()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func releaseAssertions() {
        Self.release(&displayAssertion)
        Self.release(&systemAssertion)
    }

    /// Tempo is quitting: let go of everything, lid switch first.
    func shutDown() {
        guard !didShutDown else { return }
        didShutDown = true
        releaseAssertions()
        ClosedLid.shared.shutdown()
        DriveKeeper.shared.cleanUp()
    }

    /// The display assertion also holds off the screen saver. When the user
    /// still wants the saver, start it ourselves once they've been idle for
    /// the system's saver delay — as Amphetamine does.
    private func maybeStartScreenSaver(awake: AwakeConfig) {
        guard let state, state.displayOn, awake.allowScreenSaver else {
            screenSaverFiredForIdle = false
            return
        }
        // Real idle time: the cursor nudge's own events don't count as activity.
        let idle = CursorNudger.shared.realIdle()
        let delay = TimeInterval(max(1, awake.screenSaverMinutes)) * 60
        if idle < delay {
            screenSaverFiredForIdle = false
        } else if !screenSaverFiredForIdle {
            screenSaverFiredForIdle = true
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func refreshEnvironment() {
        var next = AwakeEnvironment()
        let power = Self.readPower()
        next.onAC = power.onAC
        next.hasBattery = power.hasBattery
        next.batteryPercent = power.percent
        next.externalDisplay = NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
        next.runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let triggers = store?.config.awake.triggers ?? AwakeTriggers()
        if !triggers.wifiNetworks.isEmpty { next.wifiSSID = WiFiWatcher.shared.currentSSID() }
        if !triggers.usbDevices.isEmpty { next.usbDeviceIDs = Set(USBDevices.connected().map(\.id)) }
        if next != env { env = next }
    }

    // MARK: IOKit

    private static func create(_ type: String, _ name: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id
        )
        return result == kIOReturnSuccess ? id : 0
    }

    private static func release(_ id: inout IOPMAssertionID) {
        if id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }

    static func readPower() -> (onAC: Bool, hasBattery: Bool, percent: Int?) {
        let providing = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        let onAC = providing != kIOPMBatteryPowerKey
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (onAC, false, nil) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : nil
            return (onAC, true, percent)
        }
        return (onAC, false, nil)
    }
}

// MARK: - Notifications

enum AwakeNotifier {
    private static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static func prepare() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "tempo.awake.\(UUID().uuidString)", content: content, trigger: nil)
        )
    }
}
