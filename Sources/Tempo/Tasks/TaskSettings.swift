import SwiftUI

/// Settings → Tasks.
struct TasksSettingsSection: View {
    @EnvironmentObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingToggle("Group by due date", isOn: $store.config.tasks.groupByDue)
            caption("Splits open tasks into Overdue, Today, Upcoming and No date.")
            HStack {
                Text("Clear completed")
                    .font(.system(.subheadline, design: .rounded))
                Spacer()
                Picker("", selection: $store.config.tasks.autoClear) {
                    ForEach(TaskAutoClear.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }
            caption("Quick add: type a task and press ↩. Dates like \"tomorrow 3pm\", \"fri 9:30\" or "
                + "\"in 2 hours\" set the due time; a leading or trailing ! flags it.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
