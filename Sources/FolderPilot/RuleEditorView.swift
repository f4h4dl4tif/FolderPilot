import FolderPilotCore
import SwiftUI

struct RuleEditorView: View {
    @EnvironmentObject var model: AppModel
    @Binding var rule: Rule

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $rule.name)
                Toggle("Enabled — run automatically when files arrive", isOn: $rule.enabled)
            }

            Section("Watch") {
                ForEach(Array(rule.watch.items.enumerated()), id: \.offset) { index, folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(folder).textSelection(.enabled)
                        Spacer()
                        Button { rule.watch.items.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Stop watching this folder")
                    }
                }
                Button("Add Folder…") {
                    if let path = chooseFolder(), !rule.watch.items.contains(path) { rule.watch.items.append(path) }
                }
                Toggle("Include subfolders", isOn: $rule.recursive)
            }

            Section {
                Picker("If", selection: $rule.match) {
                    Text("all of these are true").tag(MatchMode.all)
                    Text("any of these is true").tag(MatchMode.any)
                }
                ForEach($rule.conditions) { $condition in
                    ConditionRow(condition: $condition) {
                        rule.conditions.removeAll { $0.id == condition.id }
                    }
                }
                Button("Add Condition") {
                    rule.conditions.append(Condition(field: .name, op: .contains, value: []))
                }
            } header: {
                Text("When")
            } footer: {
                if rule.conditions.isEmpty { Text("No conditions: every file in the folder matches.") }
            }

            Section {
                ForEach(Array($rule.actions.enumerated()), id: \.element.id) { index, $action in
                    ActionRow(action: $action, index: index, count: rule.actions.count) { move in
                        switch move {
                        case .up: rule.actions.swapAt(index, index - 1)
                        case .down: rule.actions.swapAt(index, index + 1)
                        case .delete: rule.actions.remove(at: index)
                        }
                    }
                }
                Menu("Add Action") {
                    ForEach(ActionType.allCases) { type in
                        Button { rule.actions.append(Self.newAction(type)) } label: { Label(type.label, systemImage: type.symbol) }
                    }
                }
                .fixedSize()
            } header: {
                Text("Do")
            } footer: {
                Text("Actions run top to bottom. Tokens use the original file's details; renaming keeps the extension unless your pattern includes {ext}.")
            }

            let issues = rule.validate()
            if !issues.isEmpty {
                Section("Needs attention") {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(rule.name.isEmpty ? "Untitled Rule" : rule.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestPreview(of: [rule], title: rule.name)
                } label: {
                    Label("Preview & Run", systemImage: "play.circle")
                }
                .help("See what this rule would do to files already in its folders, then apply")
            }
        }
    }

    static func newAction(_ type: ActionType) -> Action {
        switch type {
        case .rename: return Action(type: .rename, pattern: "{date} {name}")
        case .move: return Action(type: .move, to: "~/Documents/Sorted/{year}")
        case .copy: return Action(type: .copy, to: "~/Documents/Backup")
        case .tag: return Action(type: .tag, tags: ["FolderPilot"])
        case .trash: return Action(type: .trash)
        }
    }
}

struct ConditionRow: View {
    @Binding var condition: Condition
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $condition.field) {
                ForEach(Field.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 140)

            Picker("", selection: $condition.op) {
                ForEach(condition.field.operators) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 160)

            if condition.field == .kind {
                Picker("", selection: Binding(
                    get: { FileKind(rawValue: condition.value.items.first?.lowercased() ?? "") ?? .pdf },
                    set: { condition.value = StringList([$0.rawValue]) })
                ) {
                    ForEach(FileKind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField("", text: $condition.value.text, prompt: Text(condition.field.placeholder))
                    .labelsHidden()
            }

            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Remove condition")
        }
        .onChange(of: condition.field) { _, field in
            if !field.operators.contains(condition.op) { condition.op = field.operators[0] }
            if field == .kind { condition.value = ["pdf"] }
        }
    }
}

enum ActionEdit { case up, down, delete }

struct ActionRow: View {
    @Binding var action: Action
    let index: Int
    let count: Int
    var onEdit: (ActionEdit) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                Picker("", selection: $action.type) {
                    ForEach(ActionType.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden().frame(width: 180)
                argumentEditor
                Spacer(minLength: 0)
                Button { onEdit(.up) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(index == 0)
                Button { onEdit(.down) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(index == count - 1)
                Button { onEdit(.delete) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove action")
            }
            if [.rename, .move, .copy].contains(action.type) {
                Picker("If a file with that name exists", selection: Binding(
                    get: { action.conflictPolicy }, set: { action.onConflict = $0 })
                ) {
                    ForEach(ConflictPolicy.allCases) { Text($0.label).tag($0) }
                }
                .font(.caption)
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var argumentEditor: some View {
        switch action.type {
        case .rename:
            TextField("", text: optional(\.pattern), prompt: Text("{date} {name}")).labelsHidden()
            tokenMenu(for: \.pattern)
        case .move, .copy:
            TextField("", text: optional(\.to), prompt: Text("~/Documents/{year}")).labelsHidden()
            tokenMenu(for: \.to)
            Button("Choose…") { if let path = chooseFolder(startingAt: action.to) { action.to = path } }
        case .tag:
            TextField("", text: Binding(get: { action.tags?.text ?? "" }, set: { var l = StringList([]); l.text = $0; action.tags = l }),
                      prompt: Text("Finance, Invoices")).labelsHidden()
        case .trash:
            Text("The file goes to the Trash (recoverable).").foregroundStyle(.secondary).font(.callout)
        }
    }

    private func optional(_ keyPath: WritableKeyPath<Action, String?>) -> Binding<String> {
        Binding(get: { action[keyPath: keyPath] ?? "" }, set: { action[keyPath: keyPath] = $0 })
    }

    private func tokenMenu(for keyPath: WritableKeyPath<Action, String?>) -> some View {
        Menu {
            ForEach(Template.tokens) { t in
                Button("\(t.token)  —  \(t.help)") { action[keyPath: keyPath] = (action[keyPath: keyPath] ?? "") + t.token }
            }
        } label: {
            Image(systemName: "curlybraces")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a token")
    }
}
