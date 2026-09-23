import AppKit
import SwiftUI

/// Settings → Switcher.
struct SwitcherSettingsSection: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var controller = SwitcherController.shared
    @ObservedObject private var permissions = PermissionCenter.shared

    private var config: SwitcherConfig { store.config.switcher }
    private var theme: Theme { store.config.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if config.enabled {
                permissionRow
                row("Hold") {
                    Picker("", selection: $store.config.switcher.modifier) {
                        ForEach(HoldModifier.allCases) { Text($0.symbol + " ⇥").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if config.modifier == .command {
                    caption("⌘⇥ replaces the built-in app switcher while Tempo runs.")
                }
                row("Style") {
                    Picker("", selection: $store.config.switcher.style) {
                        ForEach(SwitcherStyle.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if config.style == .thumbnails {
                    row("Size") {
                        Picker("", selection: $store.config.switcher.size) {
                            ForEach(SwitcherSize.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                row("Windows") {
                    Picker("", selection: $store.config.switcher.scope) {
                        ForEach(WindowScope.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                row("Screen") {
                    Picker("", selection: $store.config.switcher.screen) {
                        ForEach(SwitcherScreen.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                toggle("\(config.modifier.symbol)` cycles the current app's windows", $store.config.switcher.appWindowsKey)
                toggle("Show minimized windows", $store.config.switcher.showMinimized)
                toggle("Show hidden apps", $store.config.switcher.showHidden)
                toggle("Hovering selects", $store.config.switcher.hoverSelects)
                toggle("Pointer follows the switch", $store.config.switcher.cursorFollowsFocus)
                toggle("Key hints", $store.config.switcher.showKeyHints)
                if config.style == .thumbnails {
                    previewRow
                }
                hiddenApps
            }
        }
        .onAppear { permissions.watch() }
    }

    @ViewBuilder
    private var permissionRow: some View {
        if controller.accessibilityGranted {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text("Accessibility allowed · hold \(config.modifier.symbol) and press ⇥")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            PermissionRow(
                icon: "hand.raised.fill", name: "Accessibility",
                purpose: "Needed to catch \(config.modifier.symbol)⇥ and bring windows forward.",
                status: .needed, theme: theme
            ) { Permissions.askAccessibility() }
        }
    }

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                toggle("Live previews", $store.config.switcher.previews)
                if config.previews && !permissions.screenRecording {
                    Button("Allow") { Permissions.askScreenRecording() }
                    .controlSize(.small)
                }
            }
            if config.previews && !permissions.screenRecording {
                caption("Previews need Screen Recording; until then cards show app icons.")
            }
        }
    }

    private var hiddenApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Never show")
                .font(.system(.subheadline, design: .rounded))
            TagChips(items: config.hiddenApps, theme: theme, addLabel: "Add app") {
                Text($0.name)
            } icon: {
                Image(nsImage: $0.icon).resizable().frame(width: 14, height: 14)
            } remove: { app in
                store.config.switcher.hiddenApps.removeAll { $0 == app }
            } addMenu: {
                let taken = Set(config.hiddenApps.map(\.bundleID))
                ForEach(RunningApps.regular().filter { !taken.contains($0.bundleID) }) { app in
                    Button {
                        store.config.switcher.hiddenApps.append(app)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: RunningApps.menuIcon(app)) }
                    }
                }
            }
        }
    }

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
