import FolderPilotCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(GlassTheme.key) private var glassTheme = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch FolderPilot at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle("Pause all rules", isOn: $model.isPaused)
                Toggle(isOn: $glassTheme) {
                    Text("Liquid Glass theme")
                    Text(GlassTheme.isSupported
                         ? "Use Liquid Glass for the status bar and action buttons."
                         : "Requires macOS 26.")
                }
                .disabled(!GlassTheme.isSupported)
            }
            Section("Rules file") {
                LabeledContent("Location") {
                    Text((RuleStore.defaultRulesURL.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reveal in Finder") { model.revealRulesFile() }
                    Button("Reload from Disk") { model.reloadFromDisk() }
                }
                Text("Rules are plain YAML. Edit them by hand or share them as .folderpilot files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Button("Clear Activity History", role: .destructive) { model.clearHistory() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
