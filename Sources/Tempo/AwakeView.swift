import AppKit
import SwiftUI

/// The Awake tab: what's keeping the Mac up right now, one-tap sessions,
/// and (folded away) the options and automatic triggers.
struct AwakeTab: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var engine = AwakeEngine.shared
    var now: Date
    @ViewState private var expanded: Expander?
    @ViewState private var showCustom = false

    enum Expander { case options, auto }

    private var theme: Theme { store.config.theme }
    private var awake: AwakeConfig { store.config.awake }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusCard
            quickStart
            expander(.options, title: "Options", icon: "slider.horizontal.3", summary: optionsSummary) {
                optionsBody
            }
            expander(.auto, title: "Automatic", icon: "wand.and.stars", summary: autoSummary) {
                autoBody
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let state = engine.state
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                statusRing(state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(state))
                        .font(.system(.headline, design: .rounded))
                    Text(subtitle(state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            actionRow(state)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(state == nil ? AnyShapeStyle(Color.clear) : AnyShapeStyle(theme.gradient.opacity(0.55)),
                              lineWidth: 1)
        )
        .animation(.spring(duration: 0.3), value: state)
    }

    @ViewBuilder
    private func statusRing(_ state: AwakeState?) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 5)
            if state != nil {
                Circle()
                    .trim(from: 0, to: ringFraction(state))
                    .stroke(AngularGradient(colors: theme.colors + [theme.colors[0]], center: .center),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: ringFraction(state))
            }
            ringCenter(state)
        }
        .frame(width: 58, height: 58)
    }

    @ViewBuilder
    private func ringCenter(_ state: AwakeState?) -> some View {
        if let session = state?.session {
            if let end = session.endsAt {
                Text(AwakePlanner.menuBarRemaining(end.timeIntervalSince(now)))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else if let app = session.app {
                Image(nsImage: app.icon).resizable().frame(width: 28, height: 28)
            } else {
                Image(systemName: "infinity")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.gradient)
            }
        } else if state != nil {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.gradient)
        } else {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
        }
    }

    private func ringFraction(_ state: AwakeState?) -> Double {
        guard let session = state?.session, let end = session.endsAt else { return 1 }
        let total = end.timeIntervalSince(session.startedAt)
        guard total > 0 else { return 0 }
        return min(max(end.timeIntervalSince(now) / total, 0), 1)
    }

    private func title(_ state: AwakeState?) -> String {
        guard let state else { return "Sleeping normally" }
        if let session = state.session {
            if let end = session.endsAt { return "Awake · \(AwakePlanner.remaining(end.timeIntervalSince(now))) left" }
            if let app = session.app { return "Awake while \(app.name) is open" }
            return "Awake until you stop"
        }
        return "Awake automatically"
    }

    private func subtitle(_ state: AwakeState?) -> String {
        guard let state else {
            if let reason = engine.lastEndReason { return "Last session ended: \(reason.lowercased())." }
            return "Your Mac sleeps on its usual schedule."
        }
        let display = state.displayOn ? "screen stays on" : "screen may sleep"
        switch state.source {
        case .manual(let session):
            if let end = session.endsAt { return "Until \(AwakePlanner.untilLabel(end, now: now)) · \(display)" }
            return display.prefix(1).uppercased() + display.dropFirst()
        case .trigger(let reason):
            return "\(reason) · \(display)"
        }
    }

    @ViewBuilder
    private func actionRow(_ state: AwakeState?) -> some View {
        HStack(spacing: 8) {
            if let session = state?.session {
                pill("Stop", icon: "stop.fill", filled: false) { engine.stop() }
                if session.endsAt != nil {
                    pill("+15m", icon: nil, filled: false) { engine.extend(minutes: 15) }
                    pill("+1h", icon: nil, filled: false) { engine.extend(minutes: 60) }
                }
            } else {
                pill(awake.defaultMinutes > 0 ? "Keep awake · \(AwakePlanner.durationLabel(awake.defaultMinutes))"
                        : "Keep awake", icon: "bolt.fill", filled: true) {
                    engine.begin(minutes: awake.defaultMinutes)
                }
                if state?.isTrigger == true {
                    pill("Pause auto", icon: "pause.fill", filled: false) {
                        store.config.awake.triggers.enabled = false
                    }
                }
            }
        }
    }

    private func pill(_ label: String, icon: String?, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(label)
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: filled ? .infinity : nil)
            .background(Capsule().fill(filled ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.08))))
            .foregroundStyle(filled ? .white : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Quick start

    private var quickStart: some View {
        let workEnd = AwakePlanner.workEnd(on: now, schedule: store.config.schedule)
        let current = engine.state?.session
        return VStack(alignment: .leading, spacing: 8) {
            Text("Start")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(1)
            HStack(spacing: 6) {
                ForEach(awake.presets, id: \.self) { minutes in
                    chip(AwakePlanner.durationLabel(minutes), icon: nil, selected: false) {
                        engine.begin(minutes: minutes)
                    }
                }
            }
            // Wider chips on their own row, so "Until 18:00" never truncates.
            HStack(spacing: 6) {
                if let workEnd {
                    chip("Until \(AwakePlanner.clock(workEnd))", icon: "briefcase.fill",
                         selected: current?.endsAt == workEnd) {
                        engine.begin(.until(workEnd))
                    }
                    // Its natural width; Forever and Custom share what's left.
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Until today's work ends")
                }
                chip("Forever", icon: "infinity", selected: current?.kind == .indefinite) {
                    engine.begin(.indefinite)
                }
                chip("Custom", icon: "slider.horizontal.below.rectangle", selected: false) {
                    showCustom = true
                }
                .help("A length, a date and time, or while an app is open")
                .popover(isPresented: $showCustom, arrowEdge: .bottom) {
                    CustomAwakePopover(theme: theme) { kind in
                        engine.begin(kind)
                        showCustom = false
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func chipLabel(_ label: String, icon: String?, selected: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(.caption, design: .rounded).weight(.semibold))
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(
            Capsule().fill(selected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
        )
        .foregroundStyle(selected ? .white : .primary)
        .contentShape(Capsule())
    }

    private func chip(_ label: String, icon: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(label, icon: icon, selected: selected) }
            .buttonStyle(.plain)
    }

    // MARK: Expanders

    private func expander(
        _ which: Expander, title: String, icon: String, summary: String, @ViewBuilder content: () -> some View
    ) -> some View {
        let open = expanded == which
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded = open ? nil : which }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.gradient)
                        .frame(width: 16)
                    Text(title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    Spacer()
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content()
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var optionsSummary: String {
        let screen = awake.allowDisplaySleep ? "Screen may sleep" : "Screen on"
        var extras: [String] = []
        if awake.closedLid && ClosedLid.hasLid { extras.append("lid closed") }
        if awake.moveCursor { extras.append("nudge") }
        if awake.driveAlive { extras.append("drives") }
        if extras.isEmpty {
            return engine.env.hasBattery && awake.endOnLowBattery ? "\(screen) · stop at \(awake.lowBatteryPercent)%" : screen
        }
        return "\(screen) · \(extras[0])" + (extras.count > 1 ? " +\(extras.count - 1)" : "")
    }

    private var optionsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            group("Screen") {
                toggle("Keep the screen on", isOn: Binding(
                    get: { !store.config.awake.allowDisplaySleep },
                    set: { store.config.awake.allowDisplaySleep = !$0 }
                ))
                toggle("Allow screen saver", isOn: $store.config.awake.allowScreenSaver)
                    .disabled(awake.allowDisplaySleep)
                if awake.allowScreenSaver && !awake.allowDisplaySleep {
                    subRow("Starts after") {
                        minutesStepper($store.config.awake.screenSaverMinutes, range: 1...120, suffix: "idle")
                    }
                }
            }
            group("Stay active") {
                toggle("Move the pointer when idle", isOn: $store.config.awake.moveCursor)
                if awake.moveCursor {
                    subRow("After") {
                        minutesStepper($store.config.awake.moveCursorMinutes, range: 1...60, suffix: "idle")
                    }
                    if !SwitcherController.shared.accessibilityGranted {
                        hint("Needs Accessibility to move the pointer.", action: "Allow") {
                            Permissions.requestAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                    } else {
                        note("A one-pixel nudge keeps Slack, Teams and Zoom from marking you away.")
                    }
                }
                if ClosedLid.hasLid {
                    toggle("Stay awake with the lid closed", isOn: $store.config.awake.closedLid)
                    if awake.closedLid { closedLidDetail }
                }
                toggle("Keep external drives spinning", isOn: $store.config.awake.driveAlive)
                if awake.driveAlive { drivesDetail }
            }
            group("Safety") {
                if engine.env.hasBattery {
                    toggle("Stop on low battery", isOn: $store.config.awake.endOnLowBattery)
                    if awake.endOnLowBattery {
                        subRow("Below") {
                            Stepper(value: $store.config.awake.lowBatteryPercent, in: 5...95, step: 5) {
                                Text("\(awake.lowBatteryPercent)%")
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                                    .monospacedDigit()
                            }
                            .controlSize(.mini)
                        }
                    }
                    toggle("Stop when unplugged", isOn: $store.config.awake.endWhenUnplugged)
                }
                toggle("Notify when a session ends", isOn: $store.config.awake.notifyOnEnd)
            }
        }
    }

    @ObservedObject private var lid = ClosedLid.shared

    @ViewBuilder
    private var closedLidDetail: some View {
        if lid.installed {
            note(lid.active
                ? "On now: closing the lid won't sleep your Mac until this session ends."
                : "Closing the lid won't sleep your Mac while a session runs. Keep it out of a bag — it can get hot.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("macOS only allows this with an admin's OK. Tempo asks once, then turns it on and off by itself — and always back off when the session ends or Tempo quits.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        lid.install()
                    } label: {
                        HStack(spacing: 4) {
                            if lid.busy { ProgressView().controlSize(.mini) }
                            Text(lid.busy ? "Waiting…" : "Allow once…")
                        }
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.gradient))
                        .foregroundStyle(.white)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(lid.busy)
                    Spacer(minLength: 0)
                }
                if let error = lid.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 12)
        }
    }

    private var drivesDetail: some View {
        let mounted = DriveKeeper.externalVolumes()
        return VStack(alignment: .leading, spacing: 6) {
            TagChips(items: awake.drives, theme: theme, addLabel: awake.drives.isEmpty ? "Only some…" : "Add drive") {
                Text($0.name)
            } icon: { _ in
                Image(systemName: "externaldrive.fill").font(.system(size: 9))
            } remove: { drive in
                store.config.awake.drives.removeAll { $0.id == drive.id }
            } addMenu: {
                let taken = Set(awake.drives.map(\.id))
                let free = mounted.filter { !taken.contains($0.id) }
                if free.isEmpty { Text("No other drives connected") }
                ForEach(free) { drive in
                    Button(drive.name) { store.config.awake.drives.append(drive) }
                }
            }
            note(awake.drives.isEmpty
                ? (mounted.isEmpty ? "Covers every external drive. None connected right now."
                    : "Covers every external drive: \(mounted.map(\.name).joined(separator: ", ")).")
                : "Touches a hidden file on these drives every minute while awake.")
                .padding(.leading, -12)
        }
        .padding(.leading, 12)
    }

    private var autoSummary: String {
        let t = awake.triggers
        guard t.anyConfigured else { return "Off" }
        if !t.enabled { return "Paused" }
        if case .trigger(let reason) = engine.state?.source { return reason }
        return t.ruleCount == 1 ? "1 rule" : "\(t.ruleCount) rules"
    }

    private var autoBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stay awake by itself whenever any of these is true.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            toggle("During work hours", isOn: $store.config.awake.triggers.workHours)
            toggle("An external display is connected", isOn: $store.config.awake.triggers.externalDisplay)
            if engine.env.hasBattery {
                toggle("Plugged in to power", isOn: $store.config.awake.triggers.onPower)
            }
            ruleGroup("One of these apps is open") {
                TagChips(items: awake.triggers.apps, theme: theme, addLabel: "Add app") {
                    Text($0.name)
                } icon: {
                    Image(nsImage: $0.icon).resizable().frame(width: 14, height: 14)
                } remove: { app in
                    store.config.awake.triggers.apps.removeAll { $0 == app }
                } addMenu: {
                    let taken = Set(awake.triggers.apps.map(\.bundleID))
                    ForEach(RunningApps.regular().filter { !taken.contains($0.bundleID) }) { app in
                        Button {
                            store.config.awake.triggers.apps.append(app)
                        } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: RunningApps.menuIcon(app)) }
                        }
                    }
                }
            }
            ruleGroup("On one of these Wi-Fi networks") { WiFiRule(theme: theme) }
            ruleGroup("One of these USB devices is plugged in") {
                TagChips(items: awake.triggers.usbDevices, theme: theme, addLabel: "Add device") {
                    Text($0.name)
                } icon: { _ in
                    Image(systemName: "cable.connector").font(.system(size: 9))
                } remove: { device in
                    store.config.awake.triggers.usbDevices.removeAll { $0.id == device.id }
                } addMenu: {
                    let taken = Set(awake.triggers.usbDevices.map(\.id))
                    let free = USBDevices.connected().filter { !taken.contains($0.id) }
                    if free.isEmpty { Text("No other USB devices plugged in") }
                    ForEach(free) { device in
                        Button(device.name) { store.config.awake.triggers.usbDevices.append(device) }
                    }
                }
            }
            if awake.triggers.anyConfigured {
                Divider()
                toggle("Automatic keep-awake on", isOn: $store.config.awake.triggers.enabled)
            }
        }
    }

    private func ruleGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
            content()
        }
    }

    /// A small heading over a run of related switches.
    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .kerning(0.8)
                .padding(.top, 2)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 12)
    }

    private func hint(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(action, action: perform)
                .buttonStyle(.plain)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(theme.gradient)
        }
        .padding(.leading, 12)
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        SettingToggle(label, isOn: isOn)
    }

    private func subRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            Spacer()
            content()
        }
    }

    private func minutesStepper(_ value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        Stepper(value: value, in: range) {
            Text("\(value.wrappedValue)m \(suffix)")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .controlSize(.mini)
    }
}

/// Removable chips plus an "Add" menu chip (apps, drives, networks, devices).
struct TagChips<Item: Identifiable, Title: View, Icon: View, AddMenu: View>: View {
    var items: [Item]
    var theme: Theme
    var addLabel: String
    @ViewBuilder var title: (Item) -> Title
    @ViewBuilder var icon: (Item) -> Icon
    var remove: (Item) -> Void
    @ViewBuilder var addMenu: () -> AddMenu

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    icon(item)
                    title(item).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button { remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(.caption, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            Menu {
                addMenu()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    Text(addLabel).lineLimit(1)
                }
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(Capsule().strokeBorder(theme.gradient, lineWidth: 1))
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }
}

/// Wi-Fi networks that keep the Mac awake. macOS only reveals network
/// names to apps with Location access, so this asks for it in place.
struct WiFiRule: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var wifi = WiFiWatcher.shared
    var theme: Theme
    @ViewState private var typing = false
    @ViewState private var typed = ""

    private var networks: [String] { store.config.awake.triggers.wifiNetworks }

    var body: some View {
        let current = wifi.currentSSID()
        VStack(alignment: .leading, spacing: 6) {
            TagChips(items: networks.map(Network.init), theme: theme, addLabel: "Add network") {
                Text($0.id)
            } icon: { _ in
                Image(systemName: "wifi").font(.system(size: 9, weight: .semibold))
            } remove: { network in
                store.config.awake.triggers.wifiNetworks.removeAll { $0 == network.id }
            } addMenu: {
                if let current, !networks.contains(current) {
                    Button("Current network: \(current)") { add(current) }
                    Divider()
                }
                Button("Type a name…") { typing = true }
            }
            if typing {
                HStack(spacing: 6) {
                    TextField("Network name", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit(commit)
                    Button("Add", action: commit)
                        .controlSize(.small)
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !wifi.authorized {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    Text(wifi.denied ? "macOS hides network names until Tempo has Location access."
                        : "Tempo needs Location access to see which network you're on.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(wifi.denied ? "Open Settings" : "Allow") {
                        if wifi.denied { wifi.openLocationSettings() } else { wifi.requestAccess() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(theme.gradient)
                }
            }
        }
    }

    private func commit() {
        add(typed.trimmingCharacters(in: .whitespaces))
        typed = ""
        typing = false
    }

    private func add(_ name: String) {
        guard !name.isEmpty, !networks.contains(name) else { return }
        store.config.awake.triggers.wifiNetworks.append(name)
    }

    private struct Network: Identifiable {
        var id: String
    }
}

enum RunningApps {
    /// Apps with a Dock presence, alphabetically, never Tempo itself.
    @MainActor
    static func regular() -> [AppRef] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap(AppRef.init)
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Menus draw images at their natural size; give them a 16pt copy.
    static func menuIcon(_ app: AppRef) -> NSImage {
        let icon = app.icon.copy() as? NSImage ?? app.icon
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// Everything the chips can't do: any length, any date and time, or
/// "while this app is open".
struct CustomAwakePopover: View {
    var theme: Theme
    var start: (AwakeSessionKind) -> Void
    @ViewState private var mode = Mode.duration
    @ViewState private var hours = 1
    @ViewState private var minutes = 30
    @ViewState private var until = CustomAwakePopover.defaultUntil()

    enum Mode: String, CaseIterable, Identifiable {
        case duration = "For"
        case until = "Until"
        case app = "While app"
        var id: String { rawValue }
    }

    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch mode {
            case .duration: durationBody
            case .until: untilBody
            case .app: appBody
            }
        }
        .padding(14)
        .frame(width: 284)
    }

    // MARK: For

    private var durationBody: some View {
        let total = hours * 60 + minutes
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                NumberDial(value: $hours, range: 0...72, step: 1, unit: hours == 1 ? "hour" : "hours", theme: theme)
                NumberDial(value: $minutes, range: 0...55, step: 5, unit: "min", theme: theme)
            }
            HStack(spacing: 6) {
                ForEach([15, 45, 180, 480], id: \.self) { m in
                    Button {
                        hours = m / 60
                        minutes = m % 60
                    } label: {
                        Text(AwakePlanner.durationLabel(m))
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(total == m ? AnyShapeStyle(theme.gradient)
                                : AnyShapeStyle(Color.primary.opacity(0.07))))
                            .foregroundStyle(total == m ? .white : .primary)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            summary(total > 0
                ? "Ends \(AwakePlanner.untilLabel(AwakePlanner.end(afterMinutes: total, from: Date()), now: Date()))"
                : "Pick a length", ok: total > 0)
            startButton(total > 0 ? "Start · \(AwakePlanner.durationLabel(total))" : "Start", enabled: total > 0) {
                start(.until(AwakePlanner.end(afterMinutes: total, from: Date())))
            }
        }
    }

    // MARK: Until

    private var untilBody: some View {
        let now = Date()
        let valid = until > now.addingTimeInterval(30)
        return VStack(alignment: .leading, spacing: 10) {
            DatePicker("", selection: dayBinding, in: cal.startOfDay(for: now)..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                Text("At")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                Spacer(minLength: 0)
                ForEach([9, 18], id: \.self) { hour in
                    Button(hourLabel(hour)) { setHour(hour) }
                        .buttonStyle(.plain)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            summary(valid
                ? "Ends \(AwakePlanner.untilLabel(until, now: now)) · in \(AwakePlanner.remaining(until.timeIntervalSince(now)))"
                : "That time has already passed", ok: valid)
            startButton(valid ? "Start · until \(AwakePlanner.untilLabel(until, now: now))" : "Start", enabled: valid) {
                start(.until(until))
            }
        }
    }

    private var dayBinding: Binding<Date> {
        Binding { until } set: { until = AwakePlanner.combine(day: $0, time: until, cal: cal) }
    }

    private var timeBinding: Binding<Date> {
        Binding { until } set: { until = AwakePlanner.combine(day: until, time: $0, cal: cal) }
    }

    private func setHour(_ hour: Int) {
        if let time = cal.date(bySettingHour: hour, minute: 0, second: 0, of: until) { until = time }
    }

    private func hourLabel(_ hour: Int) -> String {
        AwakePlanner.clock(cal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date())
    }

    /// Three hours out, on a quarter hour.
    static func defaultUntil(now: Date = Date()) -> Date {
        let later = now.addingTimeInterval(3 * 3600)
        let minute = Calendar.current.component(.minute, from: later)
        let rounded = later.addingTimeInterval(TimeInterval((15 - minute % 15) % 15) * 60)
        return Calendar.current.date(bySetting: .second, value: 0, of: rounded) ?? rounded
    }

    // MARK: While app

    private var appBody: some View {
        let apps = RunningApps.regular()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Stay awake until the app quits.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(apps) { app in
                        AppPickRow(app: app, theme: theme) { start(.whileApp(app)) }
                    }
                }
            }
            .frame(height: min(CGFloat(max(apps.count, 1)) * 30, 240))
            if apps.isEmpty {
                Text("No apps running").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Pieces

    private func summary(_ text: String, ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "clock" : "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .monospacedDigit()
        }
        .foregroundStyle(ok ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(Color.orange))
    }

    private func startButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
                Text(label).lineLimit(1).minimumScaleFactor(0.85)
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.gradient))
            .foregroundStyle(.white)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A big number with − / + on either side and its unit underneath.
struct NumberDial: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step: Int
    var unit: String
    var theme: Theme

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                button("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.gradient)
                    .frame(minWidth: 44)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.15), value: value)
                button("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
            }
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.8)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func button(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(enabled ? 0.08 : 0.03)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
    }
}

/// One running app in the "While app" list; highlights under the pointer.
struct AppPickRow: View {
    var app: AppRef
    var theme: Theme
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                Text(app.name)
                    .font(.system(.subheadline, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.gradient)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Settings → Awake: the global shortcut and session defaults.
struct AwakeSettingsSection: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var lid = ClosedLid.shared

    private static let durations = [0, 15, 30, 60, 120, 240, 480]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shortcut")
                    .font(.system(.subheadline, design: .rounded))
                Spacer()
                ShortcutRecorder(combo: $store.config.awake.toggleShortcut, theme: store.config.theme)
            }
            Text("Starts or stops keeping your Mac awake from anywhere.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Text("Keep awake button")
                    .font(.system(.subheadline, design: .rounded))
                Spacer()
                Picker("", selection: $store.config.awake.defaultMinutes) {
                    ForEach(Self.durations, id: \.self) { m in
                        Text(m == 0 ? "Until stopped" : AwakePlanner.durationLabel(m)).tag(m)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
            }
            HStack {
                Text("Warn before it ends")
                    .font(.system(.subheadline, design: .rounded))
                Spacer()
                Picker("", selection: $store.config.awake.warnBeforeEndMinutes) {
                    Text("Off").tag(0)
                    Text("1 min").tag(1)
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 130)
            }
            toggle("Show time left in the menu bar", $store.config.awake.showTimeInMenuBar)
            toggle("Keep awake when Tempo launches", $store.config.awake.startAtLaunch)
            toggle("Play a sound on start and stop", $store.config.awake.sounds)
            if lid.installed {
                HStack {
                    Text("Closed-lid permission")
                        .font(.system(.subheadline, design: .rounded))
                    Spacer()
                    Button("Remove…") { lid.uninstall() }
                        .controlSize(.small)
                        .disabled(lid.busy)
                }
                Text("Takes away the sudo rule that lets Tempo keep the Mac awake with the lid closed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        SettingToggle(label, isOn: isOn)
    }
}
