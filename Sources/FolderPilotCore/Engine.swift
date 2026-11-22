import Foundation

/// One step of a plan, computed without touching the disk.
public struct PlannedOperation: Codable, Equatable, Hashable {
    public var kind: ActionType
    public var source: URL
    public var destination: URL?
    public var tags: [String]?
    /// Destination exists and the rule says to replace it (the old file goes to the Trash).
    public var replacesExisting: Bool = false

    public var summary: String {
        switch kind {
        case .rename: return "Rename → \(destination?.lastPathComponent ?? "?")"
        case .move: return "Move → \(Engine.displayPath(destination?.deletingLastPathComponent()))"
        case .copy: return "Copy → \(Engine.displayPath(destination?.deletingLastPathComponent()))"
        case .tag: return "Tag \((tags ?? []).joined(separator: ", "))"
        case .trash: return "Move to Trash"
        }
    }
}

/// What a rule would do to one file. Previewed in the UI, then executed.
public struct Plan: Identifiable {
    public let id = UUID()
    public let file: URL
    public let ruleID: UUID
    public let ruleName: String
    public var operations: [PlannedOperation]
    public var note: String?

    public var summary: String {
        var parts = operations.map(\.summary)
        if let note { parts.append(note) }
        return parts.isEmpty ? "No changes" : parts.joined(separator: "  ·  ")
    }

    public var finalURL: URL {
        operations.reduce(file) { current, op in
            (op.kind == .rename || op.kind == .move) ? (op.destination ?? current) : current
        }
    }
}

public final class Engine {
    private let fm: FileManager

    public init(fileManager: FileManager = .default) {
        fm = fileManager
    }

    // MARK: Matching

    public func matches(_ rule: Rule, facts: FileFacts, now: Date = Date()) -> Bool {
        if rule.conditions.isEmpty { return true }
        let results = rule.conditions.lazy.map { self.evaluate($0, facts: facts, now: now) }
        return rule.match == .all ? results.allSatisfy { $0 } : results.contains(true)
    }

    public func evaluate(_ c: Condition, facts: FileFacts, now: Date = Date()) -> Bool {
        let values = c.value.items
        guard !values.isEmpty else { return false }

        switch c.field {
        case .size:
            guard let limit = values.first.flatMap(ValueParser.bytes) else { return false }
            return c.op == .greaterThan ? facts.size > limit : facts.size < limit

        case .created, .modified, .added:
            let date: Date? = c.field == .created ? facts.created : c.field == .modified ? facts.modified : facts.added
            guard let date, let span = values.first.flatMap(ValueParser.duration) else { return false }
            let age = now.timeIntervalSince(date)
            return c.op == .olderThan ? age > span : age <= span

        case .tags:
            let tags = Set(facts.tags.map { $0.lowercased() })
            let hit = values.contains { tags.contains($0.lowercased()) }
            return c.op == .notContains ? !hit : hit

        case .name, .fullName, .extension, .kind, .contents:
            let subject: String
            switch c.field {
            case .name: subject = facts.name
            case .fullName: subject = facts.fullName
            case .extension: subject = facts.ext
            case .kind: subject = facts.kind.rawValue
            default: subject = facts.contents
            }
            return compare(subject, c.op, values, field: c.field)
        }
    }

    private func compare(_ subject: String, _ op: Op, _ values: [String], field: Field) -> Bool {
        let s = subject.lowercased()
        func norm(_ v: String) -> String {
            var v = v.lowercased().trimmingCharacters(in: .whitespaces)
            if field == .extension, v.hasPrefix(".") { v.removeFirst() }
            return v
        }
        switch op {
        case .equals: return values.contains { s == norm($0) }
        case .notEquals: return !values.contains { s == norm($0) }
        case .contains: return values.contains { s.contains(norm($0)) }
        case .notContains: return !values.contains { s.contains(norm($0)) }
        case .startsWith: return values.contains { s.hasPrefix(norm($0)) }
        case .endsWith: return values.contains { s.hasSuffix(norm($0)) }
        case .matches:
            return values.contains { pattern in
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
                return re.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
            }
        default: return false
        }
    }

    // MARK: Scope

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Whether `file` lives in one of the rule's watched folders.
    public static func ruleWatches(_ rule: Rule, file: URL) -> Bool {
        let parent = canonical(file.deletingLastPathComponent().path)
        return rule.watch.items.contains { folder in
            let f = canonical(folder)
            return parent == f || (rule.recursive && parent.hasPrefix(f + "/"))
        }
    }

    /// First rule (in list order) that watches the file and whose conditions match. First match wins.
    public func firstMatchingRule(for file: URL, in rules: [Rule]) -> Rule? {
        let facts = FileFacts(url: file)
        return rules.first { Engine.ruleWatches($0, file: file) && matches($0, facts: facts) }
    }

    public static let temporarySuffixes: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]

    /// Regular, visible, non-temporary files in a folder.
    public func files(in folder: URL, recursive: Bool) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: options) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if Engine.temporarySuffixes.contains(url.pathExtension.lowercased()) { continue }
            out.append(url)
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Planning (dry run)

    public func plan(rule: Rule, file: URL, reserved: inout Set<String>) -> Plan {
        let facts = FileFacts(url: file)
        var current = file
        var ops: [PlannedOperation] = []
        var note: String?

        actionLoop: for action in rule.actions {
            switch action.type {
            case .rename:
                var newName = sanitizeFileName(Template.render(action.pattern ?? "{name}", facts: facts))
                if !(action.pattern ?? "").contains("{ext}"), !file.pathExtension.isEmpty {
                    newName += "." + file.pathExtension
                }
                guard !newName.isEmpty, newName != current.lastPathComponent else { continue }
                let target = current.deletingLastPathComponent().appendingPathComponent(newName)
                guard let (dest, replaces) = resolveConflict(target, source: current, policy: action.conflictPolicy, reserved: &reserved) else {
                    note = "Skipped: \(newName) already exists"
                    break actionLoop
                }
                ops.append(PlannedOperation(kind: .rename, source: current, destination: dest, replacesExisting: replaces))
                current = dest

            case .move, .copy:
                let folder = Template.resolvePath(Template.render(action.to ?? "", facts: facts),
                                                  relativeTo: current.deletingLastPathComponent())
                let target = folder.appendingPathComponent(current.lastPathComponent)
                if action.type == .move, Engine.canonical(target.path) == Engine.canonical(current.path) { continue }
                guard let (dest, replaces) = resolveConflict(target, source: current, policy: action.conflictPolicy, reserved: &reserved) else {
                    note = "Skipped: \(target.lastPathComponent) already exists in \(Engine.displayPath(folder))"
                    break actionLoop
                }
                ops.append(PlannedOperation(kind: action.type, source: current, destination: dest, replacesExisting: replaces))
                if action.type == .move { current = dest }

            case .tag:
                let tags = action.tags?.items ?? []
                if !tags.isEmpty { ops.append(PlannedOperation(kind: .tag, source: current, tags: tags)) }

            case .trash:
                ops.append(PlannedOperation(kind: .trash, source: current))
                break actionLoop
            }
        }
        return Plan(file: file, ruleID: rule.id, ruleName: rule.name, operations: ops, note: note)
    }

    /// Dry-run every file in the rules' watched folders. Rules are evaluated in order; first match wins.
    public func preview(rules: [Rule], limit: Int = 2000) -> [Plan] {
        var seen = Set<String>()
        var files: [URL] = []
        for rule in rules {
            for folder in rule.watch.items {
                let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
                for f in self.files(in: url, recursive: rule.recursive) where seen.insert(f.path).inserted {
                    files.append(f)
                }
            }
        }
        var reserved = Set<String>()
        var plans: [Plan] = []
        for file in files {
            guard let rule = firstMatchingRule(for: file, in: rules) else { continue }
            let p = plan(rule: rule, file: file, reserved: &reserved)
            if !p.operations.isEmpty || p.note != nil { plans.append(p) }
            if plans.count >= limit { break }
        }
        return plans
    }

    private func resolveConflict(_ target: URL, source: URL, policy: ConflictPolicy, reserved: inout Set<String>) -> (URL, Bool)? {
        func taken(_ u: URL) -> Bool {
            // Case-only renames on case-insensitive volumes are not conflicts.
            if u.path.lowercased() == source.path.lowercased() { return false }
            return fm.fileExists(atPath: u.path) || reserved.contains(u.path.lowercased())
        }
        var dest = target
        var replaces = false
        if taken(target) {
            switch policy {
            case .skip:
                return nil
            case .overwrite:
                replaces = true
            case .rename:
                let base = target.deletingPathExtension().lastPathComponent
                let ext = target.pathExtension
                let dir = target.deletingLastPathComponent()
                var n = 2
                repeat {
                    let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                    dest = dir.appendingPathComponent(name)
                    n += 1
                } while taken(dest)
            }
        }
        reserved.insert(dest.path.lowercased())
        return (dest, replaces)
    }

    private func sanitizeFileName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Execution

    /// Performs a plan. Never throws: stops at the first failure and records what was done so it can be undone.
    public func execute(_ plan: Plan) -> JournalEntry {
        var records: [JournalRecord] = []
        var error: String?
        do {
            for op in plan.operations {
                switch op.kind {
                case .rename, .move, .copy:
                    guard let dest = op.destination else { continue }
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if op.replacesExisting, fm.fileExists(atPath: dest.path) {
                        var trashed: NSURL?
                        try fm.trashItem(at: dest, resultingItemURL: &trashed)
                        records.append(JournalRecord(kind: .trash, from: dest.path, to: (trashed as URL?)?.path))
                    }
                    if op.kind == .copy {
                        try fm.copyItem(at: op.source, to: dest)
                    } else {
                        try fm.moveItem(at: op.source, to: dest)
                    }
                    records.append(JournalRecord(kind: op.kind, from: op.source.path, to: dest.path))

                case .tag:
                    let previous = FileFacts(url: op.source).tags
                    var merged = previous
                    for t in op.tags ?? [] where !merged.contains(t) { merged.append(t) }
                    try (op.source as NSURL).setResourceValue(merged, forKey: .tagNamesKey)
                    records.append(JournalRecord(kind: .tag, from: op.source.path, previousTags: previous, newTags: merged))

                case .trash:
                    var trashed: NSURL?
                    try fm.trashItem(at: op.source, resultingItemURL: &trashed)
                    records.append(JournalRecord(kind: .trash, from: op.source.path, to: (trashed as URL?)?.path))
                }
            }
        } catch let e {
            error = e.localizedDescription
        }
        return JournalEntry(ruleName: plan.ruleName, file: plan.file.path, records: records, error: error)
    }

    /// Reverses a journal entry's records, newest first. Returns paths that were restored.
    @discardableResult
    public func undo(_ entry: JournalEntry) throws -> [String] {
        var restored: [String] = []
        var failures: [String] = []
        for r in entry.records.reversed() {
            do {
                switch r.kind {
                case .rename, .move, .trash:
                    guard let to = r.to else { continue }
                    guard fm.fileExists(atPath: to) else { failures.append("\((to as NSString).lastPathComponent) is no longer there"); continue }
                    guard !fm.fileExists(atPath: r.from) else { failures.append("\((r.from as NSString).lastPathComponent) already exists"); continue }
                    try fm.createDirectory(at: URL(fileURLWithPath: r.from).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(atPath: to, toPath: r.from)
                    restored.append(r.from)
                case .copy:
                    guard let to = r.to, fm.fileExists(atPath: to) else { continue }
                    try fm.trashItem(at: URL(fileURLWithPath: to), resultingItemURL: nil)
                case .tag:
                    try (URL(fileURLWithPath: r.from) as NSURL).setResourceValue(r.previousTags ?? [], forKey: .tagNamesKey)
                    restored.append(r.from)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty { throw UndoError(messages: failures) }
        return restored
    }

    public static func displayPath(_ url: URL?) -> String {
        guard let url else { return "?" }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}

public struct UndoError: LocalizedError {
    public let messages: [String]
    public var errorDescription: String? { "Couldn't fully undo: " + messages.joined(separator: "; ") }
}
