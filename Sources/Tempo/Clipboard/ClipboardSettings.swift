import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Clipboard.
struct ClipboardSettingsSection: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var switcher = SwitcherController.shared
    @ObservedObject private var history = ClipboardHistory.shared
    @ViewState private var typingPattern = false
    @ViewState private var pattern = ""
    @ViewState private var confirmClear = false


    private var config: ClipboardConfig { store.config.clipboard }
    private var theme: Theme { store.config.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if config.enabled {
                HStack {
                    Text("Shortcut")
                        .font(.system(.subheadline, design: .rounded))
                    Spacer()
                    ShortcutRecorder(combo: $store.config.clipboard.shortcut, theme: theme)
                }
                caption("Opens the history popup from anywhere. Type to search, ↩ to pick.")
                row("Keep") {
                    Spacer()
                    // The value sits beside the stepper: the row hides
                    // control labels, which swallowed it as the label.
                    Text("\(config.historySize) items")
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    Stepper("Keep", value: $store.config.clipboard.historySize,
                            in: ClipboardConfig.historySizeRange, step: 10)
                        .labelsHidden()
                        .controlSize(.small)
                }
                caption("Older entries fall off past this. Pinned ones don't count and always stay.")
                row("Search") {
                    FittingPicker(selection: $store.config.clipboard.searchMode) {
                        ForEach(ClipSearchMode.allCases) { Text($0.label).tag($0) }
                    }
                }
                row("Order") {
                    FittingPicker(selection: $store.config.clipboard.sort) {
                        ForEach(ClipSort.allCases) { Text($0.label).tag($0) }
                    }
                }
                row("Opens") {
                    FittingPicker(selection: $store.config.clipboard.position) {
                        ForEach(ClipPopupPosition.allCases) { Text($0.label).tag($0) }
                    }
                }
                toggle("Paste into the front app", $store.config.clipboard.pasteOnSelect)
                pasteNote
                toggle("Paste as plain text", $store.config.clipboard.plainTextPaste)
                caption(config.plainTextPaste ? "⇧↩ keeps the formatting." : "⇧↩ pastes without formatting.")
                toggle("Pinned items on top", $store.config.clipboard.pinsOnTop)
                toggle("Save images", $store.config.clipboard.saveImages)
                toggle("Save files", $store.config.clipboard.saveFiles)
                toggle("Save formatting", $store.config.clipboard.saveRichText)
                toggle("Pause recording", $store.config.clipboard.paused)
                toggle("Clear history on quit", $store.config.clipboard.clearOnQuit)
                ignoredApps
                ignoredPatterns
                clearRow
                maccyRows
            }
        }
    }

    @ViewBuilder
    private var pasteNote: some View {
        if config.pasteOnSelect && !switcher.accessibilityGranted {
            PermissionRow(
                icon: "hand.raised.fill", name: "Accessibility",
                purpose: "Needed to press ⌘V for you. Until then, picking an entry only copies it.",
                status: .needed, theme: theme
            ) { Permissions.askAccessibility() }
        } else {
            caption(config.pasteOnSelect ? "Picking an entry pastes it where you were typing; ⌥↩ only copies."
                : "Picking an entry only copies it; ⌥↩ pastes.")
        }
    }

    private var ignoredApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Never record from")
                .font(.system(.subheadline, design: .rounded))
            TagChips(items: config.ignoredApps, theme: theme, addLabel: "Add app") {
                Text($0.name)
            } icon: {
                Image(nsImage: $0.icon).resizable().frame(width: 14, height: 14)
            } remove: { app in
                store.config.clipboard.ignoredApps.removeAll { $0 == app }
            } addMenu: {
                let taken = Set(config.ignoredApps.map(\.bundleID))
                ForEach(RunningApps.regular().filter { !taken.contains($0.bundleID) }) { app in
                    Button {
                        store.config.clipboard.ignoredApps.append(app)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: RunningApps.menuIcon(app)) }
                    }
                }
                Divider()
                Button("Choose an app…") { chooseApp() }
            }
        }
    }

    private var ignoredPatterns: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skip text matching")
                .font(.system(.subheadline, design: .rounded))
            TagChips(items: config.ignoredPatterns.map(Pattern.init), theme: theme, addLabel: "Add pattern") {
                Text($0.id).monospaced()
            } icon: { _ in
                Image(systemName: "text.magnifyingglass").font(.system(size: 9, weight: .semibold))
            } remove: { pattern in
                store.config.clipboard.ignoredPatterns.removeAll { $0 == pattern.id }
            } addMenu: {
                Button("Type a regular expression…") { typingPattern = true }
                Divider()
                ForEach(Self.examples, id: \.pattern) { example in
                    if !config.ignoredPatterns.contains(example.pattern) {
                        Button(example.label) { store.config.clipboard.ignoredPatterns.append(example.pattern) }
                    }
                }
            }
            if typingPattern {
                HStack(spacing: 6) {
                    TextField("Regular expression", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .monospaced()
                        .onSubmit(addPattern)
                    Button("Add", action: addPattern)
                        .controlSize(.small)
                        .disabled(!patternIsValid)
                    Button("Cancel") {
                        pattern = ""
                        typingPattern = false
                    }
                    .controlSize(.small)
                }
                if !pattern.isEmpty && !patternIsValid {
                    Text("That isn't a valid regular expression.")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            caption("Copies whose text matches are never saved.")
        }
    }

    private var clearRow: some View {
        HStack(spacing: 8) {
            Text("\(history.items.count) item\(history.items.count == 1 ? "" : "s") saved")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if confirmClear {
                Button("Cancel") { confirmClear = false }
                    .controlSize(.small)
                Button("Keep pinned") {
                    history.clear(keepPinned: true)
                    confirmClear = false
                }
                .controlSize(.small)
                Button("Everything", role: .destructive) {
                    history.clear(keepPinned: false)
                    confirmClear = false
                }
                .controlSize(.small)
            } else {
                Button("Clear history…") { confirmClear = true }
                    .controlSize(.small)
                    .disabled(history.items.isEmpty)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Maccy

    @ViewBuilder
    private var maccyRows: some View {
        if history.maccyRunning {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Maccy is running and may take ⇧⌘C")
                    .font(.caption)
                Spacer()
                Button("Quit Maccy") { history.quitMaccy() }
                    .controlSize(.small)
            }
            .padding(.top, 2)
        }
        if ClipboardHistory.maccyInstalled {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Import from Maccy")
                        .font(.system(.subheadline, design: .rounded))
                    Spacer()
                    if history.importing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Import") { runImport() }
                        .controlSize(.small)
                        .disabled(history.importing)
                }
                // Kept by the history: macOS's permission prompt can close this
                // panel while the import runs.
                if let result = history.lastMaccyImport {
                    Text(Self.importMessage(result))
                        .font(.caption2)
                        .foregroundStyle(isFailure(result) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                caption("Copies Maccy's history, pins included, into Tempo. macOS will ask to let Tempo read "
                    + "Maccy's data. Afterwards quit Maccy (and remove it from login items) so ⇧⌘C reaches Tempo.")
            }
            .padding(.top, 2)
        }
    }

    private func runImport() {
        let history = history
        Task { @MainActor in _ = await history.importMaccy() }
    }

    private static func importMessage(_ result: Result<Int, ClipboardImportError>) -> String {
        switch result {
        case .success(0): return "Nothing new to import."
        case .success(let count): return "Imported \(count) entr\(count == 1 ? "y" : "ies")."
        case .failure(let error): return error.message
        }
    }

    private func isFailure(_ result: Result<Int, ClipboardImportError>) -> Bool {
        if case .failure = result { return true }
        return false
    }

    // MARK: - Actions

    private var patternIsValid: Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && (try? NSRegularExpression(pattern: trimmed)) != nil
    }

    private func addPattern() {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard patternIsValid else { return }
        if !config.ignoredPatterns.contains(trimmed) { store.config.clipboard.ignoredPatterns.append(trimmed) }
        pattern = ""
        typingPattern = false
    }

    /// Password managers often aren't running; let people pick one from disk.
    private func chooseApp() {
        // The open panel takes key, which closes the menu bar panel and this
        // view with it; hold the store directly for after runModal returns.
        let store = store
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Never record"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !store.config.clipboard.ignoredApps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            store.config.clipboard.ignoredApps.append(AppRef(bundleID: id, name: name))
        }
    }

    private struct Pattern: Identifiable {
        var id: String
    }

    private static let examples: [(label: String, pattern: String)] = [
        ("Card numbers", #"^\s*(?:\d[ -]?){13,19}\s*$"#),
        ("One-time codes (6 digits)", #"^\s*\d{6}\s*$"#),
        ("API keys (sk-…)", #"^\s*sk-[A-Za-z0-9_-]{16,}\s*$"#),
    ]

    // MARK: - Layout helpers (same look as Settings → Switcher)

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(.subheadline, design: .rounded))
                .frame(width: 64, alignment: .leading)
            content()
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        SettingToggle(label, isOn: isOn)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
