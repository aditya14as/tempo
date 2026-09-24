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
    /// Whether captures work in this process. macOS only applies a new grant
    /// after a relaunch, so this stays false until then.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Whether Screen Recording is switched on right now, relaunch or not:
    /// other apps' window titles are only visible to an app that has it.
    static var screenRecordingAllowed: Bool {
        if screenRecordingGranted {
            UserDefaults.standard.removeObject(forKey: relaunchedForRecordingKey)
            return true
        }
        // Reopened for it and captures still don't work: the guess below was
        // wrong (or the switch went off). Say "Allow" again, not "Reopen".
        if UserDefaults.standard.bool(forKey: relaunchedForRecordingKey) { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        let me = getpid()
        // The cheap dictionary checks first; the app lookup last, and only
        // for the few entries that pass them.
        return list.contains { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                (entry[kCGWindowLayer as String] as? Int) == 0,
                (entry[kCGWindowOwnerName as String] as? String) != "Dock",
                !((entry[kCGWindowName as String] as? String) ?? "").isEmpty
            else { return false }
            return NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        }
    }

    static let bundleID = "com.ivy.tempo"
    private static let screenRecordingAskedKey = "tempo.screenRecordingAsked"
    private static let relaunchedForRecordingKey = "tempo.relaunchedForScreenRecording"

    /// Opens System Settings at Accessibility with the guide beside it.
    @MainActor
    static func askAccessibility() {
        // The guide's done line names what just started working.
        let reasons = ConfigStore.shared.map { PermissionNeeds($0.config).accessibilityFor } ?? []
        // Registers Tempo with the privacy database so it's already in the
        // list (switched off), without the system's own dialog on top.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        PermissionGuide.shared.show(.accessibility, readyText: reasons.isEmpty ? "Tempo can use it now"
            : reasons.joined(separator: " and ").capitalizedFirst + " is ready")
    }

    /// Asks for Screen Recording. The first time, macOS shows its own prompt
    /// (with its own button to Settings), and only that. After that it can
    /// only change in System Settings, so go there with the guide.
    @MainActor
    static func askScreenRecording() {
        guard !screenRecordingAllowed else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: screenRecordingAskedKey) {
            defaults.set(true, forKey: screenRecordingAskedKey)
            if CGRequestScreenCaptureAccess() { return }
            // macOS showed its dialog (if it still does for Tempo): watch for
            // the switch without a second prompt on top. If no dialog came
            // (macOS asks only once, ever), go to Settings with the guide.
            PermissionGuide.shared.watchSilently(.screenRecording)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let settingsUp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
                guard !screenRecordingAllowed, !settingsUp, !promptShowing() else { return }
                open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                PermissionGuide.shared.show(.screenRecording, readyText: "Reopen Tempo to start previews")
            }
            return
        }
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        PermissionGuide.shared.show(.screenRecording, readyText: "Reopen Tempo to start previews")
    }

    /// Quits and reopens Tempo, so a new Screen Recording grant takes effect.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        if !screenRecordingGranted { UserDefaults.standard.set(true, forKey: relaunchedForRecordingKey) }
        // Waits for this process to be gone, however long quitting takes,
        // or `open` would just bring the old instance forward.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 $1 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"",
                          path, "\(getpid())"]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// macOS's own Screen Recording prompt is on screen (it belongs to the
    /// UserNotificationCenter / universalAccessAuthWarn agents).
    private static func promptShowing() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { entry in
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            return owner == "UserNotificationCenter" || owner == "universalAccessAuthWarn"
        }
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

    /// Switched on in System Settings (it may still need a relaunch).
    @Published private(set) var screenRecording = Permissions.screenRecordingAllowed
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    /// The setup card was closed; it comes back next launch.
    @Published var setupHidden = false
    private var timer: Timer?
    private var watchers = 0

    /// Notifications only work from the built .app, not `swift run`.
    let notificationsAvailable = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")

    /// Screen Recording is on but this process can't capture until it reopens.
    var needsRelaunch: Bool { screenRecording && !Permissions.screenRecordingGranted }

    /// Re-reads everything now and every two seconds while any view shows it.
    func watch() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionCenter.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let recording = Permissions.screenRecordingAllowed
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
/// do there. It turns into "All set" the moment the permission comes through,
/// and goes away if System Settings closes without it, or after ten minutes.
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
            case .screenRecording: return Permissions.screenRecordingAllowed
            }
        }
    }

    private var panel: NSPanel?
    private var timer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var startedAt = Date()
    private let state = GuideState()
    private static let timeout: TimeInterval = 600

    func show(_ kind: Kind, readyText: String) {
        state.kind = kind
        state.readyText = readyText
        state.done = false
        startWatching()
        present()
    }

    /// Watches for the grant without showing anything (macOS's own prompt is
    /// up); pops up only to say what comes next once it's on.
    func watchSilently(_ kind: Kind) {
        state.kind = kind
        state.readyText = "Reopen Tempo to start previews"
        state.done = false
        panel?.orderOut(nil)
        startWatching()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        if let settingsObserver { NSWorkspace.shared.notificationCenter.removeObserver(settingsObserver) }
        settingsObserver = nil
        panel?.orderOut(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        // The screen the user is working on, which is where System Settings opens.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    private func startWatching() {
        startedAt = Date()
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionGuide.shared.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if settingsObserver == nil {
            settingsObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.systempreferences" else { return }
                MainActor.assumeIsolated { PermissionGuide.shared.settingsClosed() }
            }
        }
    }

    /// System Settings closed without the switch going on: nothing left to guide.
    private func settingsClosed() {
        guard !state.done else { return }
        close()
    }

    private func poll() {
        if !state.done, Date().timeIntervalSince(startedAt) > Self.timeout {
            close()
            return
        }
        guard !state.done, state.kind.granted else { return }
        state.done = true
        PermissionCenter.shared.refresh()
        timer?.invalidate()
        timer = nil
        switch state.kind {
        case .accessibility:
            present()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.state.done == true, self?.state.kind == .accessibility { self?.close() }
            }
        case .screenRecording:
            // Stays up with the Reopen button: captures start only after a relaunch.
            if Permissions.screenRecordingGranted { close() } else { present() }
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
    @Published var readyText = ""
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
                    Text(state.done ? state.readyText : "in the System Settings window")
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
                if state.kind == .screenRecording {
                    Button { Permissions.relaunch() } label: {
                        Text("Reopen Tempo")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(theme.gradient))
                            .foregroundStyle(.white)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                step(1, "Find **Tempo** in the list and turn its switch on.")
                step(2, "Enter your Mac password or use Touch ID if asked.")
                if state.kind == .screenRecording {
                    step(3, "If macOS offers **Quit & Reopen**, choose it.")
                }
                if Bundle.main.bundlePath.hasSuffix(".app") {
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
                }
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
        if config.isOn(.clipboard) && config.clipboard.pasteOnSelect { accessibilityFor.append("pasting from clipboard history") }
        previews = config.isOn(.switcher) && config.switcher.previews && config.switcher.style == .thumbnails
        guard PermissionCenter.shared.notificationsAvailable else { return }
        if config.isOn(.tasks) && !DueFormat.pendingReminders(config.todos, now: Date()).isEmpty {
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
                    purpose: center.needsRelaunch
                        ? "Allowed. Reopen Tempo to start live previews."
                        : "Optional. Shows live window previews in the switcher; without it, cards show app icons.",
                    status: center.needsRelaunch ? .reopen : center.screenRecording ? .allowed : .optional,
                    theme: store.config.theme
                ) { center.needsRelaunch ? Permissions.relaunch() : Permissions.askScreenRecording() }
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
        .onDisappear { center.unwatch() }
    }
}

struct PermissionRow: View {
    enum Status { case allowed, needed, optional, off, reopen }

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
                    Text(status == .off ? "Turn on" : status == .reopen ? "Reopen" : "Allow")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(status == .needed || status == .reopen ? AnyShapeStyle(theme.gradient)
                                                   : AnyShapeStyle(Color.primary.opacity(0.1))))
                        .foregroundStyle(status == .needed || status == .reopen ? .white : .primary)
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
        if let step = steps.first, !center.setupHidden {
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
                            if step == .accessibility {
                                Permissions.askAccessibility()
                            } else if center.needsRelaunch {
                                Permissions.relaunch()
                            } else {
                                Permissions.askScreenRecording()
                            }
                        } label: {
                            Text(step == .accessibility ? "Allow Accessibility"
                                 : center.needsRelaunch ? "Reopen Tempo" : "Allow previews")
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
                    center.setupHidden = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Hide for now. Settings → Permissions has these any time.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(store.config.theme.gradient.opacity(0.5), lineWidth: 1)
            )
            .onAppear { center.watch() }
            .onDisappear { center.unwatch() }
        }
    }

    private func pending(_ needs: PermissionNeeds) -> [Step] {
        var steps: [Step] = []
        if !needs.accessibilityFor.isEmpty && !switcher.accessibilityGranted { steps.append(.accessibility) }
        if needs.previews && (!center.screenRecording || center.needsRelaunch) && switcher.accessibilityGranted {
            steps.append(.previews)
        }
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
            if center.needsRelaunch { return "Screen Recording is on. Reopen Tempo once to start the previews." }
            return "Screen Recording lets the switcher show what's in each window. Tempo only takes thumbnails while the switcher is open, and never saves or sends them."
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
