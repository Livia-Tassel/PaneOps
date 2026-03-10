import SwiftUI
import SentinelShared

/// Editor for creating or modifying a custom rule.
struct RuleEditorView: View {
    let rule: Rule?
    let onSave: (Rule) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var agentType: AgentType?
    @State private var eventType: EventType = .permissionRequested
    @State private var triggersNotification: Bool = true
    @State private var highPriority: Bool = false
    @State private var cooldownSeconds: Double = 10
    @State private var patterns: [RulePattern] = []
    @State private var newPatternValue: String = ""
    @State private var newPatternKind: RulePattern.Kind = .keyword

    init(rule: Rule?, onSave: @escaping (Rule) -> Void, onCancel: @escaping () -> Void) {
        self.rule = rule
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(rule == nil ? "New Rule" : "Edit Rule")
                .font(.headline)
                .padding()

            formContent
                .padding()

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    let saved = Rule(
                        id: rule?.id ?? UUID(),
                        name: name,
                        agentType: agentType,
                        patterns: patterns,
                        eventType: eventType,
                        priority: highPriority ? .high : .normal,
                        triggersNotification: triggersNotification,
                        isBuiltin: false,
                        isEnabled: true,
                        cooldownSeconds: cooldownSeconds
                    )
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || patterns.isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
        .onAppear {
            if let rule {
                name = rule.name
                agentType = rule.agentType
                eventType = rule.eventType
                triggersNotification = rule.triggersNotification
                highPriority = rule.highPriority
                cooldownSeconds = rule.cooldownSeconds
                patterns = rule.patterns
            }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Name:") {
                TextField("Rule name", text: $name)
            }

            LabeledContent("Agent:") {
                Picker("", selection: $agentType) {
                    Text("Any").tag(AgentType?.none)
                    ForEach(AgentType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(AgentType?.some(type))
                    }
                }
                .labelsHidden()
            }

            LabeledContent("Event Type:") {
                Picker("", selection: $eventType) {
                    ForEach(EventType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
            }

            Toggle("Trigger Notification", isOn: $triggersNotification)
            Toggle("High Priority", isOn: $highPriority)

            LabeledContent("Cooldown:") {
                HStack {
                    TextField("", value: $cooldownSeconds, format: .number)
                        .frame(width: 50)
                    Text("seconds")
                }
            }

            Divider()

            Text("Patterns (OR logic)")
                .font(.subheadline.bold())

            ForEach(patterns) { pattern in
                HStack {
                    Text(pattern.kind == .keyword ? "Keyword" : "Regex")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 50)
                    Text(pattern.value)
                        .font(.caption.monospaced())
                    Spacer()
                    Button {
                        patterns.removeAll { $0.id == pattern.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Picker("", selection: $newPatternKind) {
                    Text("Keyword").tag(RulePattern.Kind.keyword)
                    Text("Regex").tag(RulePattern.Kind.regex)
                }
                .labelsHidden()
                .frame(width: 90)

                TextField("Pattern value", text: $newPatternValue)

                Button("Add") {
                    guard !newPatternValue.isEmpty else { return }
                    patterns.append(RulePattern(kind: newPatternKind, value: newPatternValue))
                    newPatternValue = ""
                }
            }
        }
    }
}
