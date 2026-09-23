import AppKit
import SwiftUI

/// Settings → Switcher.
struct SwitcherSettingsSection: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var controller = SwitcherController.shared
    @ViewState private var screenRecording = Permissions.screenRecordingGranted

    private var config: SwitcherConfig { store.config.switcher }
    private var theme: Theme { store.config.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggle("Window switcher", $store.config.switcher.enabled)
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
        .onAppear { screenRecording = Permissions.screenRecordingGranted }
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
            SwitcherPermissionCard(dismissible: false)
        }
    }

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                toggle("Live previews", $store.config.switcher.previews)
                if config.previews && !screenRecording {
                    Button("Allow") {
                        if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() }
                    }
                    .controlSize(.small)
                }
            }
            if config.previews && !screenRecording {
                caption("Previews need Screen Recording; until then cards show app icons. Relaunch Tempo after allowing.")
            }
        }
    }

    private var hiddenApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Never show")
                .font(.system(.subheadline, design: .rounded))
            FlowChips(items: config.hiddenApps, theme: theme) { app in
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

/// "Allow Accessibility" — the one step the switcher needs. Shown on the Now
/// tab until granted (or dismissed) and inside the switcher settings.
struct SwitcherPermissionCard: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var controller = SwitcherController.shared
    var dismissible = true

    var body: some View {
        if !controller.accessibilityGranted && store.config.switcher.enabled
            && !(dismissible && store.config.switcher.onboardingDismissed) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(store.config.theme.gradient)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turn on the \(store.config.switcher.modifier.symbol)⇥ window switcher")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text("Allow Tempo under Accessibility so it can switch windows. It works the moment you flip the switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    } label: {
                        Text("Open Settings")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(store.config.theme.gradient))
                            .foregroundStyle(.white)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Text(Permissions.staleGrantHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if dismissible {
                    Button {
                        store.config.switcher.onboardingDismissed = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Hide — you can turn it on later in Settings")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.orange.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            )
        }
    }
}
