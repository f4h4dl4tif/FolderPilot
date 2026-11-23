import AppKit
import SwiftUI

@main
struct FolderPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("FolderPilot", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Rule") { model.addRule() }.keyboardShortcut("n")
            }
            CommandMenu("Rules") {
                Button("Run All Rules Now…") { model.requestPreview(of: model.ruleSet.rules.filter(\.enabled), title: "All enabled rules") }
                    .keyboardShortcut("r")
                Button(model.isPaused ? "Resume Watching" : "Pause Watching") { model.isPaused.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Import Workflow…") { model.importWorkflow() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Export All Rules…") { model.exportRules(model.ruleSet.rules, suggestedName: "My Rules") }
                Divider()
                Button("Reload Rules from Disk") { model.reloadFromDisk() }
                Button("Reveal Rules File in Finder") { model.revealRulesFile() }
            }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: model.isPaused ? "pause.circle" : "folder.badge.gearshape")
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        GlassSnapshot.runIfRequested()
    }

    /// Keep watching folders from the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
