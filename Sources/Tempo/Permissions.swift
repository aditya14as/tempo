import AppKit
import ApplicationServices
import SwiftUI
import UserNotifications

/// The system permissions Tempo can use, and a guided way to grant them.
///
/// Tempo asks for nothing at launch. Each permission is requested only when a
/// feature that needs it is on, and `PermissionGuide` walks the user through
/// System Settings instead of dropping them there.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    static let bundleID = "com.ivy.tempo"

    /// Opens System Settings at Accessibility with the guide beside it.
    @MainActor
    static func askAccessibility() {
        // Registers Tempo with the privacy database so it's already in the
        // list (switched off), without the system's own dialog on top.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        PermissionGuide.shared.show(.accessibility)
    }

    /// Asks for Screen Recording. The first time macOS shows its own prompt;
    /// after that it only changes in System Settings, so go there with the guide.
    @MainActor
    static func askScreenRecording() {
        if CGRequestScreenCaptureAccess() { return }
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        PermissionGuide.shared.show(.screenRecording)
    }

    static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

/// Live permission state for the settings list and the setup card.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var screenRecording = Permissions.screenRecordingGranted
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    private var timer: Timer?

    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Re-reads everything now and every two seconds while anything shows it.
    func watch() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PermissionCenter.shared.refresh() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let recording = Permissions.screenRecordingGranted
        if recording != screenRecording { screenRecording = recording }
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if PermissionCenter.shared.notifications != status { PermissionCenter.shared.notifications = status }
                }
            }
        }
    }

    func askNotifications() {
        guard notificationsAvailable else { return }
        if notifications == .denied {
            Permissions.openNotificationSettings()
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PermissionCenter.shared.refresh() } }
        }
    }
}

// MARK: - Guide

/// A small card that floats beside System Settings and says exactly what to
/// do there. It closes by itself the moment the permission comes through.
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    enum Kind {
        case accessibility, screenRecording

        var title: String {
            switch self {
            case .accessibility: return "Allow Accessibility"
            case .screenRecording: return "Allow Screen Recording"
            }
        }

        var granted: Bool {
            switch self {
            case .accessibility: return Permissions.accessibilityGranted
            case .screenRecording: return Permissions.screenRecordingGranted
            }
        }
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private let state = GuideState()

    func show(_ kind: Kind) {
        state.kind = kind
        state.done = false
        let panel = self.panel ?? makePanel()
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24))
        }
        panel.orderFrontRegardless()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PermissionGuide.shared.poll() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func poll() {
        guard !state.done, state.kind.granted else { return }
        state.done = true
        PermissionCenter.shared.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.state.done == true { self?.close() }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = GuidePanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 10),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let hosting = GuideHostingView(rootView: GuideView(state: state, theme: ConfigStore.shared?.config.theme ?? .aurora))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.panel = panel
        return panel
    }
}

@MainActor
private final class GuideState: ObservableObject {
    @Published var kind: PermissionGuide.Kind = .accessibility
    @Published var done = false
}

/// Never takes focus, so System Settings stays the active window.
private final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class GuideHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct GuideView: View {
    @ObservedObject var state: GuideState
    var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.done ? "All set" : state.kind.title)
                        .font(.system(.headline, design: .rounded))
                    Text(state.done ? doneText : "in the System Settings window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { PermissionGuide.shared.close() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            if state.done {
                Label("Tempo is allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                step(1, "Find **Tempo** in the list and turn its switch on.")
                step(2, "Enter your Mac password or use Touch ID if asked.")
                if state.kind == .screenRecording {
                    step(3, "If macOS offers **Quit & Reopen**, choose it.")
                }
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                        .help("Drag into the list")
                    Text("Tempo not in the list? Drag this icon into it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("This closes by itself once it's on.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(VisualEffectBackground().clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.gradient, lineWidth: 1.5)
        )
        .fixedSize()
    }

    private var doneText: String {
        switch state.kind {
        case .accessibility: return "The window switcher is ready"
        case .screenRecording: return "Previews appear after Tempo reopens"
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.gradient))
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Settings and setup UI

/// What each feature that's on needs, for the settings list and setup card.
@MainActor
struct PermissionNeeds {
    var accessibilityFor: [String] = []
    var previews = false
    var notificationsFor: [String] = []

    init(_ config: AppConfig) {
        if config.isOn(.switcher) { accessibilityFor.append("the \(config.switcher.modifier.symbol)⇥ switcher") }
        if config.isOn(.awake) && config.awake.moveCursor { accessibilityFor.append("the pointer nudge") }
        previews = config.isOn(.switcher) && config.switcher.previews && config.switcher.style == .thumbnails
        if config.isOn(.tasks) && config.todos.contains(where: { $0.dueDate != nil && !$0.done }) {
            notificationsFor.append("task reminders")
        }
        if config.isOn(.awake) && (config.awake.notifyOnEnd || config.awake.warnBeforeEndMinutes > 0) {
            notificationsFor.append("Awake alerts")
        }
    }

    var isEmpty: Bool { accessibilityFor.isEmpty && !previews && notificationsFor.isEmpty }
}

/// Settings → Permissions: only what the features you use need, each with
/// its reason and a one-click way to allow it.
struct PermissionsSection: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var switcher = SwitcherController.shared
    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        let needs = PermissionNeeds(store.config)
        VStack(alignment: .leading, spacing: 10) {
            if needs.isEmpty {
                Text("Nothing to allow for the features you use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !needs.accessibilityFor.isEmpty {
                PermissionRow(
                    icon: "hand.raised.fill", name: "Accessibility",
                    purpose: "For " + needs.accessibilityFor.joined(separator: " and ") + ".",
                    status: switcher.accessibilityGranted ? .allowed : .needed,
                    theme: store.config.theme
                ) { Permissions.askAccessibility() }
            }
            if needs.previews {
                PermissionRow(
                    icon: "rectangle.on.rectangle", name: "Screen Recording",
                    purpose: "Optional. Shows live window previews in the switcher; without it, cards show app icons.",
                    status: center.screenRecording ? .allowed : .optional,
                    theme: store.config.theme
                ) { Permissions.askScreenRecording() }
            }
            if !needs.notificationsFor.isEmpty {
                PermissionRow(
                    icon: "bell.badge.fill", name: "Notifications",
                    purpose: "For " + needs.notificationsFor.joined(separator: " and ") + ".",
                    status: center.notifications == .authorized || center.notifications == .provisional
                        ? .allowed : center.notifications == .denied ? .off : .optional,
                    theme: store.config.theme
                ) { center.askNotifications() }
            }
            Text("Tempo asks only when a feature you turn on needs it. Wi-Fi rules and Apple Reminders ask the first time you use them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { center.watch() }
    }
}

struct PermissionRow: View {
    enum Status { case allowed, needed, optional, off }

    var icon: String
    var name: String
    var purpose: String
    var status: Status
    var theme: Theme
    var allow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(.subheadline, design: .rounded).weight(.semibold))
                Text(purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if status == .allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(action: allow) {
                    Text(status == .off ? "Turn on" : "Allow")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(status == .needed ? AnyShapeStyle(theme.gradient)
                                                   : AnyShapeStyle(Color.primary.opacity(0.1))))
                        .foregroundStyle(status == .needed ? .white : .primary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The Now tab's setup card: one step at a time, required before optional,
/// and gone once everything the features need is allowed (or dismissed).
struct SetupCard: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var switcher = SwitcherController.shared
    @ObservedObject private var center = PermissionCenter.shared

    private enum Step { case accessibility, previews }

    var body: some View {
        let needs = PermissionNeeds(store.config)
        let steps = pending(needs)
        if let step = steps.first, !store.config.switcher.onboardingDismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: step == .accessibility ? "rectangle.stack.fill" : "rectangle.on.rectangle")
                    .font(.system(size: 18))
                    .foregroundStyle(store.config.theme.gradient)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title(step, needs))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Text(detail(step, needs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button {
                            step == .accessibility ? Permissions.askAccessibility() : Permissions.askScreenRecording()
                        } label: {
                            Text(step == .accessibility ? "Allow Accessibility" : "Allow previews")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(store.config.theme.gradient))
                                .foregroundStyle(.white)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        if step == .previews {
                            Button("Use app icons") { store.config.switcher.previews = false }
                                .buttonStyle(.plain)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    store.config.switcher.onboardingDismissed = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Hide. Settings → Permissions has these any time.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(store.config.theme.gradient.opacity(0.5), lineWidth: 1)
            )
            .onAppear { center.watch() }
        }
    }

    private func pending(_ needs: PermissionNeeds) -> [Step] {
        var steps: [Step] = []
        if !needs.accessibilityFor.isEmpty && !switcher.accessibilityGranted { steps.append(.accessibility) }
        if needs.previews && !center.screenRecording && switcher.accessibilityGranted { steps.append(.previews) }
        return steps
    }

    private func title(_ step: Step, _ needs: PermissionNeeds) -> String {
        switch step {
        case .accessibility:
            return store.config.isOn(.switcher)
                ? "One step to turn on \(store.config.switcher.modifier.symbol)⇥"
                : "One step for the pointer nudge"
        case .previews:
            return "Optional: live window previews"
        }
    }

    private func detail(_ step: Step, _ needs: PermissionNeeds) -> String {
        switch step {
        case .accessibility:
            return "Tempo needs Accessibility for " + needs.accessibilityFor.joined(separator: " and ")
                + ". A guide shows you where to click."
        case .previews:
            return "Screen Recording lets the switcher show what's in each window. Tempo only takes thumbnails while the switcher is open, and never saves or sends them."
        }
    }
}
