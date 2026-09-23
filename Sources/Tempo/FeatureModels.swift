import AppKit
import Foundation

// MARK: - Tolerant decoding
// New settings must never wipe a saved config: every field decodes
// independently and falls back to its default when missing or malformed.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

// MARK: - Shared

/// A running (or remembered) app, by bundle identifier, with a display name.
struct AppRef: Codable, Equatable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    init?(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return nil }
        self.init(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    /// The app's icon, or a generic one if it isn't installed any more.
    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}

/// A global keyboard shortcut: a virtual key code plus modifier flags
/// (NSEvent.ModifierFlags raw value, device-independent bits only).
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .option, .control, .shift]).rawValue
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "⌃⌥A" — what the settings row shows.
    var label: String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// A shortcut without any modifier would fire while typing; refuse it.
    var isUsable: Bool { !flags.isEmpty || Self.functionKeys.contains(keyCode) }

    static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    static func keyName(_ code: UInt16) -> String {
        if let name = keyNames[code] { return name }
        return "Key \(code)"
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 76: "⌤", 96: "F5", 97: "F6",
        98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2",
        122: "F1", 115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

// MARK: - Awake (keep the Mac from sleeping)

/// What ends a keep-awake session.
enum AwakeSessionKind: Codable, Equatable {
    /// Runs until you stop it.
    case indefinite
    /// Runs until a moment in time (timed presets and "until 18:00" both land here).
    case until(Date)
    /// Runs while an app is open; ends the moment it quits.
    case whileApp(AppRef)
}

/// One active keep-awake session. Persisted so a relaunch resumes it.
struct AwakeSession: Codable, Equatable {
    var kind: AwakeSessionKind
    var startedAt: Date = Date()
    /// Snapshot of the setting when the session began.
    var allowDisplaySleep: Bool = false

    var endsAt: Date? {
        if case .until(let date) = kind { return date }
        return nil
    }

    var app: AppRef? {
        if case .whileApp(let app) = kind { return app }
        return nil
    }
}

/// Conditions under which Tempo keeps the Mac awake on its own.
struct AwakeTriggers: Codable, Equatable {
    /// Master switch — pause all triggers without forgetting them.
    var enabled = true
    var externalDisplay = false
    var onPower = false
    /// Tempo already knows your schedule; stay awake during work hours.
    var workHours = false
    var apps: [AppRef] = []

    var anyConfigured: Bool { externalDisplay || onPower || workHours || !apps.isEmpty }

    init() {}

    private enum CodingKeys: String, CodingKey { case enabled, externalDisplay, onPower, workHours, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AwakeTriggers()
        enabled = c.value(.enabled, or: d.enabled)
        externalDisplay = c.value(.externalDisplay, or: d.externalDisplay)
        onPower = c.value(.onPower, or: d.onPower)
        workHours = c.value(.workHours, or: d.workHours)
        apps = c.value(.apps, or: d.apps)
    }
}

struct AwakeConfig: Codable, Equatable {
    /// Keep the system awake but let the display sleep (Amphetamine's
    /// "Allow display sleep"). Off = screen stays on too.
    var allowDisplaySleep = false
    /// Let the screen saver start while a session runs.
    var allowScreenSaver = false
    /// Safety: end the session when the battery drops this low.
    var endOnLowBattery = true
    var lowBatteryPercent = 15
    /// End (and don't auto-start) sessions while unplugged.
    var endWhenUnplugged = false
    var notifyOnEnd = true
    /// Minutes before a timed session ends to warn; 0 = no warning.
    var warnBeforeEndMinutes = 0
    var sounds = false
    /// Start an indefinite session when Tempo launches.
    var startAtLaunch = false
    /// Duration used by the shortcut and the one-click toggle; 0 = indefinite.
    var defaultMinutes = 60
    /// Quick-start chips, in minutes.
    var presets: [Int] = [30, 60, 120, 240]
    var showTimeInMenuBar = true
    var toggleShortcut: KeyCombo? = nil
    var triggers = AwakeTriggers()
    /// The running manual session, if any (survives a relaunch).
    var session: AwakeSession? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case allowDisplaySleep, allowScreenSaver, endOnLowBattery, lowBatteryPercent, endWhenUnplugged
        case notifyOnEnd, warnBeforeEndMinutes, sounds, startAtLaunch, defaultMinutes, presets
        case showTimeInMenuBar, toggleShortcut, triggers, session
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AwakeConfig()
        allowDisplaySleep = c.value(.allowDisplaySleep, or: d.allowDisplaySleep)
        allowScreenSaver = c.value(.allowScreenSaver, or: d.allowScreenSaver)
        endOnLowBattery = c.value(.endOnLowBattery, or: d.endOnLowBattery)
        lowBatteryPercent = c.value(.lowBatteryPercent, or: d.lowBatteryPercent)
        endWhenUnplugged = c.value(.endWhenUnplugged, or: d.endWhenUnplugged)
        notifyOnEnd = c.value(.notifyOnEnd, or: d.notifyOnEnd)
        warnBeforeEndMinutes = c.value(.warnBeforeEndMinutes, or: d.warnBeforeEndMinutes)
        sounds = c.value(.sounds, or: d.sounds)
        startAtLaunch = c.value(.startAtLaunch, or: d.startAtLaunch)
        defaultMinutes = c.value(.defaultMinutes, or: d.defaultMinutes)
        presets = c.value(.presets, or: d.presets)
        showTimeInMenuBar = c.value(.showTimeInMenuBar, or: d.showTimeInMenuBar)
        toggleShortcut = c.value(.toggleShortcut, or: d.toggleShortcut)
        triggers = c.value(.triggers, or: d.triggers)
        session = c.value(.session, or: d.session)
    }
}

// MARK: - Switcher (⌥⇥ window switcher)

/// The key you hold to open the switcher.
enum HoldModifier: String, Codable, CaseIterable, Identifiable {
    case option, control, command

    var id: String { rawValue }
    var label: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        }
    }
    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        }
    }
}

enum SwitcherStyle: String, Codable, CaseIterable, Identifiable {
    case thumbnails, icons, titles

    var id: String { rawValue }
    var label: String {
        switch self {
        case .thumbnails: return "Previews"
        case .icons: return "Icons"
        case .titles: return "List"
        }
    }
}

enum SwitcherSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Which windows the switcher lists.
enum WindowScope: String, Codable, CaseIterable, Identifiable {
    case allSpaces, currentSpace

    var id: String { rawValue }
    var label: String {
        switch self {
        case .allSpaces: return "All Spaces"
        case .currentSpace: return "This Space"
        }
    }
}

/// Which display the switcher appears on.
enum SwitcherScreen: String, Codable, CaseIterable, Identifiable {
    case mouse, active, main

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mouse: return "With mouse"
        case .active: return "Active window"
        case .main: return "Main"
        }
    }
}

struct SwitcherConfig: Codable, Equatable {
    var enabled = true
    var modifier: HoldModifier = .option
    /// Hold the modifier and press ` to cycle only the active app's windows.
    var appWindowsKey = true
    var style: SwitcherStyle = .thumbnails
    var size: SwitcherSize = .medium
    var scope: WindowScope = .allSpaces
    var showMinimized = true
    var showHidden = true
    var showFullscreen = true
    var screen: SwitcherScreen = .mouse
    /// After switching, move the pointer to the focused window.
    var cursorFollowsFocus = true
    /// Hovering a card moves the selection (release then focuses it).
    var hoverSelects = true
    var showKeyHints = true
    var showSpaceBadges = true
    /// Live window previews (needs Screen Recording access; falls back to icons).
    var previews = true
    /// Apps whose windows never appear in the switcher.
    var hiddenApps: [AppRef] = []
    /// The first-run "grant Accessibility" card was dismissed.
    var onboardingDismissed = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, modifier, appWindowsKey, style, size, scope, showMinimized, showHidden, showFullscreen
        case screen, cursorFollowsFocus, hoverSelects, showKeyHints, showSpaceBadges, previews, hiddenApps, onboardingDismissed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SwitcherConfig()
        enabled = c.value(.enabled, or: d.enabled)
        modifier = c.value(.modifier, or: d.modifier)
        appWindowsKey = c.value(.appWindowsKey, or: d.appWindowsKey)
        style = c.value(.style, or: d.style)
        size = c.value(.size, or: d.size)
        scope = c.value(.scope, or: d.scope)
        showMinimized = c.value(.showMinimized, or: d.showMinimized)
        showHidden = c.value(.showHidden, or: d.showHidden)
        showFullscreen = c.value(.showFullscreen, or: d.showFullscreen)
        screen = c.value(.screen, or: d.screen)
        cursorFollowsFocus = c.value(.cursorFollowsFocus, or: d.cursorFollowsFocus)
        hoverSelects = c.value(.hoverSelects, or: d.hoverSelects)
        showKeyHints = c.value(.showKeyHints, or: d.showKeyHints)
        showSpaceBadges = c.value(.showSpaceBadges, or: d.showSpaceBadges)
        previews = c.value(.previews, or: d.previews)
        hiddenApps = c.value(.hiddenApps, or: d.hiddenApps)
        onboardingDismissed = c.value(.onboardingDismissed, or: d.onboardingDismissed)
    }
}
