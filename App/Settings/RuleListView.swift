import SwiftUI
import SentinelShared

/// List of built-in and custom rules with enable/disable toggles.
struct RuleListView: View {
    @Binding var config: AppConfig
    @Binding var showingEditor: Bool
    @Binding var editingRule: Rule?

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Built-in Rules") {
                    ForEach(BuiltinRules.all) { rule in
                        RuleRowView(
                            rule: rule,
                            isEnabled: !config.disabledBuiltinRuleIds.contains(rule.id),
                            onToggle: { enabled in
                                if enabled {
                                    config.disabledBuiltinRuleIds.remove(rule.id)
                                } else {
                                    config.disabledBuiltinRuleIds.insert(rule.id)
                                }
                            }
                        )
                    }
                }

                Section("Custom Rules") {
                    if config.customRules.isEmpty {
                        Text("No custom rules")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        ForEach(config.customRules) { rule in
                            RuleRowView(
                                rule: rule,
                                isEnabled: rule.isEnabled,
                                onToggle: { enabled in
                                    if let idx = config.customRules.firstIndex(where: { $0.id == rule.id }) {
                                        config.customRules[idx].isEnabled = enabled
                                    }
                                },
                                onEdit: {
                                    editingRule = rule
                                    showingEditor = true
                                },
                                onDelete: {
                                    config.customRules.removeAll { $0.id == rule.id }
                                }
                            )
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Add Rule") {
                    editingRule = nil
                    showingEditor = true
                }
                .padding(8)
            }
        }
    }
}

struct RuleRowView: View {
    let rule: Rule
    let isEnabled: Bool
    let onToggle: (Bool) -> Void
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(get: { isEnabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(rule.name)
                        .font(.subheadline)
                    if rule.priority == .high {
                        Text("HIGH")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: rule.eventType.sfSymbol)
                        .font(.caption2)
                    Text(rule.eventType.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !rule.triggersNotification {
                        Text("· silent")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let agentType = rule.agentType {
                        Text("· \(agentType.displayName)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if onEdit != nil {
                Button {
                    onEdit?()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }

            if onDelete != nil {
                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
    }
}
