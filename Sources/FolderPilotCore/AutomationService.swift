import Foundation

/// Ties the watcher, engine and journal together:
/// event → wait until the file stops changing → first matching rule → execute → journal.
public final class AutomationService {
    public enum Event {
        case processed(JournalEntry)
        case undone(JournalEntry)
    }

    public let engine: Engine
    public let journal: Journal
    /// Called on the main queue.
    public var onEvent: ((Event) -> Void)?

    private let queue = DispatchQueue(label: "FolderPilot.automation")
    private var watcher: FolderWatcher!
    private var rules: [Rule] = []
    private var running = false
    private var pending: [String: PendingFile] = [:]
    /// Paths FolderPilot itself just wrote; their events are ignored so rules don't loop.
    private var produced: [String: Date] = [:]
    private var timer: DispatchSourceTimer?

    /// Seconds a file's size and date must stay unchanged before it is processed (downloads, copies).
    public var settleTicks = 2
    public var ignoreWindow: TimeInterval = 10

    private struct PendingFile {
        var size: Int64 = -1
        var modified: Date?
        var stableTicks = 0
    }

    public init(engine: Engine = Engine(), journal: Journal) {
        self.engine = engine
        self.journal = journal
        watcher = FolderWatcher(queue: queue) { [weak self] paths in self?.received(paths) }
    }

    public func update(rules newRules: [Rule]) {
        queue.async {
            self.rules = newRules.filter(\.enabled)
            if self.running { self.restartWatcher() }
        }
    }

    public func start() {
        queue.async {
            self.running = true
            self.restartWatcher()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.watcher.stop()
            self.pending.removeAll()
            self.timer?.cancel()
            self.timer = nil
        }
    }

    public var watchedFolderCount: Int {
        queue.sync { Set(rules.flatMap { $0.watch.items.map(Engine.canonical) }).count }
    }

    /// Batch: execute previewed plans. Completion runs on the main queue.
    public func apply(_ plans: [Plan], completion: @escaping ([JournalEntry]) -> Void) {
        queue.async {
            var entries: [JournalEntry] = []
            for plan in plans where !plan.operations.isEmpty {
                let entry = self.engine.execute(plan)
                self.markProduced(entry)
                self.journal.append(entry)
                entries.append(entry)
            }
            DispatchQueue.main.async { completion(entries) }
        }
    }

    public func undo(_ entry: JournalEntry, completion: @escaping (Error?) -> Void) {
        queue.async {
            // Mark both ends so restoring a file into a watched folder doesn't re-trigger the rule.
            self.markProduced(entry)
            var failure: Error?
            do { try self.engine.undo(entry) } catch { failure = error }
            self.journal.markUndone(entry.id)
            var undone = entry
            undone.undone = true
            DispatchQueue.main.async {
                self.onEvent?(.undone(undone))
                completion(failure)
            }
        }
    }

    // MARK: - Private (all on `queue`)

    private func restartWatcher() {
        let folders = Set(rules.flatMap { $0.watch.items.map { ($0 as NSString).expandingTildeInPath } })
        watcher.start(paths: Array(folders))
    }

    private func markProduced(_ entry: JournalEntry) {
        let now = Date()
        for r in entry.records {
            produced[Engine.canonical(r.from)] = now
            if let to = r.to { produced[Engine.canonical(to)] = now }
        }
    }

    private func received(_ paths: [String]) {
        guard running else { return }
        let now = Date()
        produced = produced.filter { now.timeIntervalSince($0.value) < ignoreWindow }
        for path in paths {
            let key = Engine.canonical(path)
            if produced[key] != nil { continue }
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            if name.hasPrefix(".") || Engine.temporarySuffixes.contains(url.pathExtension.lowercased()) { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard rules.contains(where: { Engine.ruleWatches($0, file: url) }) else { continue }
            if pending[path] == nil { pending[path] = PendingFile() }
        }
        if !pending.isEmpty { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        for (path, var state) in pending {
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                pending[path] = nil // gone (moved away or deleted)
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            if size == state.size && values.contentModificationDate == state.modified {
                state.stableTicks += 1
            } else {
                state = PendingFile(size: size, modified: values.contentModificationDate, stableTicks: 0)
            }
            if state.stableTicks >= settleTicks {
                pending[path] = nil
                process(URL(fileURLWithPath: path))
            } else {
                pending[path] = state
            }
        }
        if pending.isEmpty {
            timer?.cancel()
            timer = nil
        }
    }

    private func process(_ url: URL) {
        guard let rule = engine.firstMatchingRule(for: url, in: rules) else { return }
        var reserved = Set<String>()
        let plan = engine.plan(rule: rule, file: url, reserved: &reserved)
        guard !plan.operations.isEmpty else { return }
        let entry = engine.execute(plan)
        markProduced(entry)
        journal.append(entry)
        DispatchQueue.main.async { self.onEvent?(.processed(entry)) }
    }
}
