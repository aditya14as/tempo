import SwiftUI

struct PanelView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings {
                SettingsView(onBack: { withAnimation(.easeInOut(duration: 0.2)) { showSettings = false } })
            } else {
                progressContent
            }
        }
        .frame(width: 324)
    }

    private var progressContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let config = store.config
            VStack(alignment: .leading, spacing: 14) {
                header(now: now)
                ForEach(Metric.allCases) { metric in
                    if config.row(metric).visible {
                        MetricRowView(
                            metric: metric,
                            snapshot: ProgressEngine.snapshot(metric, now: now, config: config),
                            style: config.row(metric).style,
                            theme: config.theme,
                            config: config,
                            now: now
                        )
                    }
                }
                footer
            }
            .padding(16)
        }
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(.headline, design: .rounded))
                Text("Tempo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(1.2)
            }
            Spacer()
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(.subheadline, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings = true }
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Tempo")
        }
        .padding(.top, 2)
    }
}

struct MetricRowView: View {
    var metric: Metric
    var snapshot: MetricSnapshot
    var style: RowStyle
    var theme: Theme
    var config: AppConfig
    var now: Date

    private var dotCount: Int {
        let cal = ProgressEngine.mondayCalendar
        switch metric {
        case .today:
            let day = ProgressEngine.daySchedule(for: now, schedule: config.schedule, cal: cal)
            return day.seconds > 0 ? min(max(Int((day.seconds / 3600).rounded()), 1), 24) : 8
        case .week:
            return min(config.schedule.weekHours, 60)
        case .month:
            return cal.range(of: .day, in: .month, for: now)?.count ?? 30
        case .year:
            return 52
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch style {
            case .percent:
                HStack(alignment: .center) {
                    titleBlock
                    Spacer()
                    BigPercent(fraction: snapshot.fraction, theme: theme)
                }
            case .bar:
                HStack(alignment: .firstTextBaseline) {
                    titleBlock
                    Spacer()
                    BigPercent(fraction: snapshot.fraction, theme: theme, size: 15)
                }
                GradientBar(fraction: snapshot.fraction ?? 0, theme: theme)
                    .opacity(snapshot.fraction == nil ? 0.4 : 1)
            case .ring:
                HStack(spacing: 12) {
                    GradientRing(fraction: snapshot.fraction ?? 0, theme: theme)
                        .opacity(snapshot.fraction == nil ? 0.4 : 1)
                    titleBlock
                    Spacer()
                }
            case .dots:
                HStack(alignment: .firstTextBaseline) {
                    titleBlock
                    Spacer()
                    BigPercent(fraction: snapshot.fraction, theme: theme, size: 15)
                }
                DotGrid(fraction: snapshot.fraction ?? 0, count: dotCount, theme: theme)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Text(snapshot.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
