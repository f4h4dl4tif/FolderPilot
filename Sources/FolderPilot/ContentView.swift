import FolderPilotCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Rules") {
                    ForEach(model.ruleSet.rules) { rule in
                        RuleRow(rule: rule)
                            .tag(SidebarItem.rule(rule.id))
                            .contextMenu {
                                Button("Preview & Run…") { model.requestPreview(of: [rule], title: rule.name) }
                                Button("Duplicate") { model.duplicate(rule) }
                                Button("Export as Workflow…") { model.exportRules([rule], suggestedName: rule.name) }
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(rule) }
                            }
                    }
                    .onMove { model.ruleSet.rules.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("History") {
                    Label("Activity", systemImage: "clock.arrow.circlepath").tag(SidebarItem.activity)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) { StatusBar() }
            .toolbar {
                ToolbarItem {
                    Button(action: model.addRule) { Label("New Rule", systemImage: "plus") }
                        .help("New rule (⌘N)")
                }
            }
        } detail: {
            switch model.selection {
            case .rule(let id):
                if let binding = model.binding(for: id) {
                    RuleEditorView(rule: binding).id(id)
                } else {
                    placeholder
                }
            case .activity:
                ActivityView()
            case nil:
                placeholder
            }
        }
        .sheet(item: $model.previewRequest) { PreviewView(request: $0) }
        .alert("FolderPilot", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("Select a rule", systemImage: "folder.badge.gearshape",
                               description: Text("Rules run, in order, on files that arrive in their watched folders. First match wins."))
    }
}

struct RuleRow: View {
    let rule: Rule

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: rule.enabled ? "bolt.circle.fill" : "bolt.slash.circle")
                .foregroundStyle(rule.enabled ? Color.accentColor : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name).lineLimit(1)
                Text(rule.watch.items.first.map { ($0 as NSString).lastPathComponent } ?? "No folder")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Circle().fill(model.isPaused ? Color.orange : (model.enabledFolderCount > 0 ? Color.green : Color.secondary))
                .frame(width: 8, height: 8)
            Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(model.isPaused ? "Resume" : "Pause") { model.isPaused.toggle() }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }
}
