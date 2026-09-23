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
            if let end = session.endsAt { return "Until \(AwakePlanner.clock(end)) · \(display)" }
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6)], spacing: 6) {
                ForEach(awake.presets, id: \.self) { minutes in
                    chip(AwakePlanner.durationLabel(minutes), icon: nil, selected: false) {
                        engine.begin(minutes: minutes)
                    }
                }
                if let workEnd {
                    chip("Until \(AwakePlanner.clock(workEnd))", icon: "briefcase.fill",
                         selected: current?.endsAt == workEnd) {
                        engine.begin(.until(workEnd))
                    }
                    .help("Until today's work ends")
                }
                chip("Forever", icon: "infinity", selected: current?.kind == .indefinite) {
                    engine.begin(.indefinite)
                }
                chip("Custom", icon: "clock", selected: false) { showCustom = true }
                    .popover(isPresented: $showCustom, arrowEdge: .bottom) {
                        CustomAwakePopover(theme: theme) { kind in
                            engine.begin(kind)
                            showCustom = false
                        }
                    }
                appMenu
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
            Text(label).lineLimit(1)
        }
        .font(.system(.caption, design: .rounded).weight(.semibold))
        .padding(.vertical, 6)
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

    /// "While an app is open": pick from the apps running right now.
    private var appMenu: some View {
        Menu {
            let apps = RunningApps.regular()
            if apps.isEmpty { Text("No apps running") }
            ForEach(apps) { app in
                Button {
                    engine.begin(.whileApp(app))
                } label: {
                    Label { Text(app.name) } icon: { Image(nsImage: RunningApps.menuIcon(app)) }
                }
            }
        } label: {
            chipLabel("While app", icon: "app.badge", selected: engine.state?.session?.app != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Stay awake while an app is open")
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
        var parts = [awake.allowDisplaySleep ? "Screen may sleep" : "Screen on"]
        if engine.env.hasBattery && awake.endOnLowBattery { parts.append("stop at \(awake.lowBatteryPercent)%") }
        return parts.joined(separator: " · ")
    }

    private var optionsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
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

    private var autoSummary: String {
        let t = awake.triggers
        guard t.anyConfigured else { return "Off" }
        if !t.enabled { return "Paused" }
        if case .trigger(let reason) = engine.state?.source { return reason }
        let count = [t.externalDisplay, t.onPower, t.workHours].filter { $0 }.count + t.apps.count
        return count == 1 ? "1 rule" : "\(count) rules"
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
            VStack(alignment: .leading, spacing: 6) {
                Text("One of these apps is open")
                    .font(.system(.subheadline, design: .rounded))
                FlowChips(items: awake.triggers.apps, theme: theme) { app in
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
            if awake.triggers.anyConfigured {
                Divider()
                toggle("Automatic keep-awake on", isOn: $store.config.awake.triggers.enabled)
            }
        }
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

/// App chips with a remove button each, plus an "Add app" menu chip.
struct FlowChips<AddMenu: View>: View {
    var items: [AppRef]
    var theme: Theme
    var remove: (AppRef) -> Void
    @ViewBuilder var addMenu: () -> AddMenu

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items) { app in
                HStack(spacing: 4) {
                    Image(nsImage: app.icon).resizable().frame(width: 14, height: 14)
                    Text(app.name).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { remove(app) } label: {
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
                    Text("Add app")
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

/// "For 1h 30m" or "Until 17:30" — the session you can't get from a chip.
struct CustomAwakePopover: View {
    var theme: Theme
    var start: (AwakeSessionKind) -> Void
    @ViewState private var mode = 0
    @ViewState private var hours = 1
    @ViewState private var minutes = 30
    @ViewState private var until = Date().addingTimeInterval(3 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $mode) {
                Text("For").tag(0)
                Text("Until").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if mode == 0 {
                HStack(spacing: 14) {
                    Stepper(value: $hours, in: 0...23) {
                        Text("\(hours)h").monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                    Stepper(value: $minutes, in: 0...55, step: 5) {
                        Text("\(minutes)m").monospacedDigit().frame(width: 30, alignment: .trailing)
                    }
                }
                .font(.system(.title3, design: .rounded).weight(.semibold))
            } else {
                HStack {
                    DatePicker("", selection: $until, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                    Text(untilCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                if mode == 0 {
                    start(.until(AwakePlanner.end(afterMinutes: max(1, hours * 60 + minutes), from: Date())))
                } else {
                    start(.until(AwakePlanner.nextOccurrence(ofTimeIn: until, after: Date())))
                }
            } label: {
                Text("Start")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(theme.gradient))
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(mode == 0 && hours == 0 && minutes == 0)
        }
        .padding(14)
        .frame(width: 230)
    }

    private var untilCaption: String {
        let next = AwakePlanner.nextOccurrence(ofTimeIn: until, after: Date())
        return Calendar.current.isDateInToday(next) ? "today" : "tomorrow"
    }
}

/// Settings → Awake: the global shortcut and session defaults.
struct AwakeSettingsSection: View {
    @EnvironmentObject var store: ConfigStore

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
        }
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        SettingToggle(label, isOn: isOn)
    }
}
