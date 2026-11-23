import AppKit
import FolderPilotCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case rule(UUID)
    case activity
}

struct PreviewRequest: Identifiable {
    let id = UUID()
    let title: String
    let rules: [Rule]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var ruleSet: RuleSet {
        didSet { if ruleSet != oldValue { scheduleSave() } }
    }
    @Published var selection: SidebarItem? = .activity
    @Published var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "paused")
            isPaused ? service.stop() : service.start()
        }
    }
    @Published private(set) var history: [JournalEntry] = []
    @Published var previewRequest: PreviewRequest?
    @Published var alertMessage: String?

    let engine = Engine()
    let service: AutomationService
    private var saveTask: Task<Void, Never>?

    init() {
        let journal = Journal(url: RuleStore.defaultJournalURL)
        service = AutomationService(engine: engine, journal: journal)
        isPaused = UserDefaults.standard.bool(forKey: "paused")
        do {
            ruleSet = try RuleStore.loadOrCreateDefault()
        } catch {
            ruleSet = RuleSet()
            alertMessage = "Couldn't read rules.yaml: \(error.localizedDescription). Fix the file and choose Rules ▸ Reload."
        }
        if let first = ruleSet.rules.first { selection = .rule(first.id) }
        history = journal.entries
        service.onEvent = { [weak self] _ in self?.refreshHistory() }
        service.update(rules: ruleSet.rules)
        AppModel.current = self
        // A DEBUG glass-snapshot run only looks at the UI; it never watches folders or runs rules.
        if !isPaused && !GlassSnapshot.isRequested { service.start() }
    }

    static weak var current: AppModel?

    var enabledFolderCount: Int {
        Set(ruleSet.rules.filter(\.enabled).flatMap(\.watch.items)).count
    }

    var statusText: String {
        if isPaused { return "Paused" }
        let n = enabledFolderCount
        return n == 0 ? "No enabled rules" : "Watching \(n) folder\(n == 1 ? "" : "s")"
    }

    // MARK: Rules

    func binding(for id: UUID) -> Binding<Rule>? {
        guard ruleSet.rules.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [unowned self] in self.ruleSet.rules.first { $0.id == id } ?? Rule(name: "") },
            set: { [unowned self] newValue in
                if let i = self.ruleSet.rules.firstIndex(where: { $0.id == id }) { self.ruleSet.rules[i] = newValue }
            })
    }

    func addRule() {
        let rule = Rule(
            name: "New Rule", enabled: false, watch: ["~/Downloads"],
            conditions: [Condition(field: .extension, op: .equals, value: "pdf")],
            actions: [Action(type: .move, to: "~/Documents/Sorted/{year}")])
        ruleSet.rules.append(rule)
        selection = .rule(rule.id)
    }

    func duplicate(_ rule: Rule) {
        var copy = rule
        copy.id = UUID()
        copy.name += " copy"
        copy.enabled = false
        if let i = ruleSet.rules.firstIndex(where: { $0.id == rule.id }) {
            ruleSet.rules.insert(copy, at: i + 1)
        } else {
            ruleSet.rules.append(copy)
        }
        selection = .rule(copy.id)
    }

    func delete(_ rule: Rule) {
        ruleSet.rules.removeAll { $0.id == rule.id }
        if selection == .rule(rule.id) { selection = ruleSet.rules.first.map { .rule($0.id) } ?? .activity }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try RuleStore.save(self.ruleSet, to: RuleStore.defaultRulesURL)
            } catch {
                self.alertMessage = "Couldn't save rules: \(error.localizedDescription)"
            }
            self.service.update(rules: self.ruleSet.rules)
        }
    }

    func reloadFromDisk() {
        do {
            ruleSet = try RuleStore.load(from: RuleStore.defaultRulesURL)
            service.update(rules: ruleSet.rules)
        } catch {
            alertMessage = "Couldn't read rules.yaml: \(error.localizedDescription)"
        }
    }

    func revealRulesFile() {
        NSWorkspace.shared.activateFileViewerSelecting([RuleStore.defaultRulesURL])
    }

    // MARK: Preview & batch

    func requestPreview(of rules: [Rule], title: String) {
        guard !rules.isEmpty else {
            alertMessage = "There are no enabled rules to run."
            return
        }
        previewRequest = PreviewRequest(title: title, rules: rules)
    }

    func preview(_ rules: [Rule]) async -> [Plan] {
        let engine = self.engine
        return await Task.detached(priority: .userInitiated) { engine.preview(rules: rules) }.value
    }

    func apply(_ plans: [Plan]) async -> [JournalEntry] {
        await withCheckedContinuation { cont in
            service.apply(plans) { [weak self] entries in
                self?.refreshHistory()
                cont.resume(returning: entries)
            }
        }
    }

    // MARK: History

    func refreshHistory() { history = service.journal.entries }

    var lastUndoable: JournalEntry? { history.first(where: \.canUndo) }

    func undo(_ entry: JournalEntry) {
        service.undo(entry) { [weak self] error in
            self?.refreshHistory()
            if let error { self?.alertMessage = error.localizedDescription }
        }
    }

    func clearHistory() {
        service.journal.clear()
        refreshHistory()
    }

    func reveal(_ entry: JournalEntry) {
        guard let path = entry.currentPath else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            alertMessage = "\((path as NSString).lastPathComponent) is no longer at that location."
        }
    }

    // MARK: Import / export (.folderpilot = a shareable YAML rule set)

    func importWorkflow() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.yaml, .data]
        panel.message = "Choose .folderpilot or .yaml workflow files"
        guard panel.runModal() == .OK else { return }
        var imported = 0
        for url in panel.urls {
            do {
                for var rule in try RuleStore.load(from: url).rules {
                    rule.id = UUID()
                    rule.enabled = false // imported workflows never run until reviewed
                    ruleSet.rules.append(rule)
                    imported += 1
                }
            } catch {
                alertMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if imported > 0, let last = ruleSet.rules.last {
            selection = .rule(last.id)
            alertMessage = "Imported \(imported) rule\(imported == 1 ? "" : "s"). They're disabled until you review and enable them."
        }
    }

    func exportRules(_ rules: [Rule], suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".folderpilot"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RuleStore.save(RuleSet(rules: rules), to: url)
        } catch {
            alertMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                alertMessage = "Couldn't change Launch at Login: \(error.localizedDescription). Move FolderPilot to /Applications and try again."
            }
            objectWillChange.send()
        }
    }
}

func chooseFolder(startingAt path: String? = nil) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if let path { panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return (url.path as NSString).abbreviatingWithTildeInPath
}
