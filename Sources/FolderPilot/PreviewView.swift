import FolderPilotCore
import SwiftUI

/// Dry run → review → apply. Nothing changes on disk until Apply.
struct PreviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PreviewRequest

    @State private var plans: [Plan]?
    @State private var excluded: Set<UUID> = []
    @State private var applying = false
    @State private var resultText: String?

    private var actionable: [Plan] { (plans ?? []).filter { !$0.operations.isEmpty && !excluded.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview: \(request.title)").font(.title2.bold())
                Text("Files already in the watched folders that match. Nothing changes until you click Apply.")
                    .foregroundStyle(.secondary)
            }

            Group {
                if let plans {
                    if plans.isEmpty {
                        ContentUnavailableView("No matching files", systemImage: "checkmark.circle",
                                               description: Text("Nothing in the watched folders matches right now."))
                    } else {
                        Table(plans) {
                            TableColumn("") { plan in
                                Toggle("", isOn: Binding(
                                    get: { !excluded.contains(plan.id) },
                                    set: { if $0 { excluded.remove(plan.id) } else { excluded.insert(plan.id) } }))
                                .labelsHidden()
                                .disabled(plan.operations.isEmpty)
                            }
                            .width(24)
                            TableColumn("File") { Text($0.file.lastPathComponent).lineLimit(1).help($0.file.path) }
                                .width(min: 160, ideal: 220)
                            TableColumn("Rule") { Text($0.ruleName).foregroundStyle(.secondary) }
                                .width(min: 90, ideal: 140)
                            TableColumn("Result") { plan in
                                Text(plan.summary).lineLimit(2)
                                    .foregroundStyle(plan.note != nil ? Color.orange : Color.primary)
                                    .help(plan.summary)
                            }
                        }
                    }
                } else {
                    ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            HStack {
                if let resultText {
                    Label(resultText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if plans != nil {
                    Text("\(actionable.count) file\(actionable.count == 1 ? "" : "s") will change. You can undo from Activity.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(resultText == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if resultText == nil {
                    Button(applying ? "Applying…" : "Apply") { Task { await apply() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(actionable.isEmpty || applying)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 460)
        .task { plans = await model.preview(request.rules) }
    }

    private func apply() async {
        applying = true
        let entries = await model.apply(actionable)
        applying = false
        let failed = entries.filter { $0.error != nil }.count
        resultText = "Changed \(entries.count - failed) file\(entries.count - failed == 1 ? "" : "s")" + (failed > 0 ? ", \(failed) failed (see Activity)" : "")
    }
}
