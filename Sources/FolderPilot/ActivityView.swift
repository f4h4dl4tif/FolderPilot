import FolderPilotCore
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Every change FolderPilot makes appears here and can be undone."))
            } else {
                List(model.history) { entry in
                    ActivityRow(entry: entry)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItemGroup {
                Button { if let e = model.lastUndoable { model.undo(e) } } label: { Label("Undo Last", systemImage: "arrow.uturn.backward") }
                    .disabled(model.lastUndoable == nil)
                Button { model.clearHistory() } label: { Label("Clear History", systemImage: "trash") }
                    .disabled(model.history.isEmpty)
            }
        }
    }
}

struct ActivityRow: View {
    @EnvironmentObject var model: AppModel
    let entry: JournalEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.error != nil ? "exclamationmark.triangle.fill" : entry.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                .foregroundStyle(entry.error != nil ? Color.orange : entry.undone ? Color.secondary : Color.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.fileName).fontWeight(.medium).lineLimit(1)
                    Text(entry.ruleName).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Text(entry.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(entry.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if entry.undone {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
            } else if entry.canUndo {
                Button("Undo") { model.undo(entry) }
            }
            Button { model.reveal(entry) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.vertical, 4)
    }
}
