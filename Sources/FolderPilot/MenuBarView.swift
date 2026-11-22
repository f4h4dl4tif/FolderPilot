import FolderPilotCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        Divider()
        Button(model.isPaused ? "Resume Watching" : "Pause Watching") { model.isPaused.toggle() }
        Button("Run All Rules Now…") {
            showWindow()
            model.requestPreview(of: model.ruleSet.rules.filter(\.enabled), title: "All enabled rules")
        }
        Button("Undo Last Change") { if let e = model.lastUndoable { model.undo(e) } }
            .disabled(model.lastUndoable == nil)

        if !model.history.isEmpty {
            Divider()
            Text("Recent")
            ForEach(model.history.prefix(5)) { entry in
                Button("\(entry.fileName) — \(entry.records.last?.summary ?? entry.ruleName)") { model.reveal(entry) }
            }
        }

        Divider()
        Button("Open FolderPilot") { showWindow() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit FolderPilot") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
