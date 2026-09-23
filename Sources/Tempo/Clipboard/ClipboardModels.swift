import AppKit
import Foundation

// MARK: - Clipboard history (the Maccy side of Tempo)

/// What a history entry mostly is — decides its icon and how it's shown.
enum ClipKind: String, Codable, CaseIterable {
    case text, richText, image, files, color, link
}

/// One copy in the history. The raw pasteboard data lives on disk
/// (see `ClipboardHistory`); this is the light part the UI lists.
struct ClipItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: ClipKind = .text
    /// One-line text shown in the list (and searched): the copied text,
    /// file names, or "Image 1200×800".
    var title: String = ""
    /// Pasteboard types stored for this entry, in the order they were copied.
    var types: [String] = []
    /// The app that was in front when it was copied.
    var appBundleID: String?
    var appName: String?
    var firstCopied = Date()
    var lastCopied = Date()
    var copies = 1
    /// A letter (b…y) when pinned: pinned entries stay on top, survive
    /// "Clear" and the size limit, and ⌘+letter picks them in the popup.
    var pin: String?
    /// Total size of the stored data, in bytes.
    var bytes = 0
    /// Text read out of an image entry (Vision), searched along with the
    /// title and offered as "Copy text". Nil until read, or for non-images.
    var ocrText: String?

    init() {}

    var isPinned: Bool { pin != nil }
}

/// How typing in the popup matches entries.
enum ClipSearchMode: String, Codable, CaseIterable, Identifiable {
    case exact, fuzzy, regex

    var id: String { rawValue }
    var label: String {
        switch self {
        case .exact: return "Exact"
        case .fuzzy: return "Fuzzy"
        case .regex: return "Regex"
        }
    }
}

/// Order of the (unpinned) history.
enum ClipSort: String, Codable, CaseIterable, Identifiable {
    case lastCopied, firstCopied, copyCount

    var id: String { rawValue }
    var label: String {
        switch self {
        case .lastCopied: return "Last copied"
        case .firstCopied: return "First copied"
        case .copyCount: return "Most copied"
        }
    }
}

/// Where the popup opens.
enum ClipPopupPosition: String, Codable, CaseIterable, Identifiable {
    case cursor, center, menuBar

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cursor: return "At pointer"
        case .center: return "Screen centre"
        case .menuBar: return "Under menu bar"
        }
    }
}

struct ClipboardConfig: Codable, Equatable {
    var enabled = true
    /// Opens the history popup. Default ⇧⌘C, like Maccy.
    var shortcut: KeyCombo? = KeyCombo(keyCode: 8, modifiers: [.command, .shift])
    /// Unpinned entries kept; older ones fall off.
    var historySize = 200
    var searchMode: ClipSearchMode = .exact
    var sort: ClipSort = .lastCopied
    var position: ClipPopupPosition = .cursor
    /// Picking an entry pastes it into the front app (needs Accessibility);
    /// off = it's only copied, and ⌥ pastes.
    var pasteOnSelect = true
    /// Pasting drops formatting (plain text only); ⇧ does the opposite.
    var plainTextPaste = false
    var pinsOnTop = true
    var saveImages = true
    var saveFiles = true
    var saveRichText = true
    /// Recording is paused (⌥-click in the tab / popup toggle).
    var paused = false
    /// Copies from these apps are never recorded (password managers by default).
    var ignoredApps: [AppRef] = ClipboardConfig.defaultIgnoredApps
    /// Extra pasteboard types that mark a copy as "don't record".
    var ignoredTypes: [String] = []
    /// Copies whose text matches one of these regexes are skipped.
    var ignoredPatterns: [String] = []
    var clearOnQuit = false

    static let defaultIgnoredApps: [AppRef] = [
        AppRef(bundleID: "com.1password.1password", name: "1Password"),
        AppRef(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        AppRef(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        AppRef(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        AppRef(bundleID: "com.apple.Passwords", name: "Passwords"),
    ]

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, shortcut, historySize, searchMode, sort, position, pasteOnSelect, plainTextPaste
        case pinsOnTop, saveImages, saveFiles, saveRichText, paused, ignoredApps, ignoredTypes
        case ignoredPatterns, clearOnQuit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardConfig()
        enabled = c.value(.enabled, or: d.enabled)
        // A cleared shortcut is saved as null and must stay cleared.
        shortcut = c.contains(.shortcut) ? c.value(.shortcut, or: nil) : d.shortcut
        historySize = c.value(.historySize, or: d.historySize)
        searchMode = c.value(.searchMode, or: d.searchMode)
        sort = c.value(.sort, or: d.sort)
        position = c.value(.position, or: d.position)
        pasteOnSelect = c.value(.pasteOnSelect, or: d.pasteOnSelect)
        plainTextPaste = c.value(.plainTextPaste, or: d.plainTextPaste)
        pinsOnTop = c.value(.pinsOnTop, or: d.pinsOnTop)
        saveImages = c.value(.saveImages, or: d.saveImages)
        saveFiles = c.value(.saveFiles, or: d.saveFiles)
        saveRichText = c.value(.saveRichText, or: d.saveRichText)
        paused = c.value(.paused, or: d.paused)
        ignoredApps = c.value(.ignoredApps, or: d.ignoredApps)
        ignoredTypes = c.value(.ignoredTypes, or: d.ignoredTypes)
        ignoredPatterns = c.value(.ignoredPatterns, or: d.ignoredPatterns)
        clearOnQuit = c.value(.clearOnQuit, or: d.clearOnQuit)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(shortcut, forKey: .shortcut)  // null when cleared, not omitted
        try c.encode(historySize, forKey: .historySize)
        try c.encode(searchMode, forKey: .searchMode)
        try c.encode(sort, forKey: .sort)
        try c.encode(position, forKey: .position)
        try c.encode(pasteOnSelect, forKey: .pasteOnSelect)
        try c.encode(plainTextPaste, forKey: .plainTextPaste)
        try c.encode(pinsOnTop, forKey: .pinsOnTop)
        try c.encode(saveImages, forKey: .saveImages)
        try c.encode(saveFiles, forKey: .saveFiles)
        try c.encode(saveRichText, forKey: .saveRichText)
        try c.encode(paused, forKey: .paused)
        try c.encode(ignoredApps, forKey: .ignoredApps)
        try c.encode(ignoredTypes, forKey: .ignoredTypes)
        try c.encode(ignoredPatterns, forKey: .ignoredPatterns)
        try c.encode(clearOnQuit, forKey: .clearOnQuit)
    }
}
