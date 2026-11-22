import Foundation
import Yams

/// Reads and writes rule sets as YAML (`rules.yaml`, `*.folderpilot`).
public enum RuleStore {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderPilot", isDirectory: true)
    }
    public static var defaultRulesURL: URL { supportDirectory.appendingPathComponent("rules.yaml") }
    public static var defaultJournalURL: URL { supportDirectory.appendingPathComponent("journal.json") }

    public static func decode(_ yaml: String) throws -> RuleSet {
        let set = try YAMLDecoder().decode(RuleSet.self, from: yaml)
        guard set.version <= RuleSet.currentVersion else {
            throw RuleStoreError.newerVersion(set.version)
        }
        return set
    }

    public static func encode(_ set: RuleSet) throws -> String {
        let header = """
        # FolderPilot rules (format version \(RuleSet.currentVersion))
        # Edit in the app, or by hand. Tokens: {name} {ext} {kind} {date} {date:FORMAT} {year} {month}
        # {monthName} {day} {created} {modified} {added} {now} {parent}

        """
        return header + (try YAMLEncoder().encode(set))
    }

    public static func load(from url: URL) throws -> RuleSet {
        try decode(String(contentsOf: url, encoding: .utf8))
    }

    public static func save(_ set: RuleSet, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(set).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Loads the user's rules, creating the starter file on first launch.
    public static func loadOrCreateDefault() throws -> RuleSet {
        let url = defaultRulesURL
        if FileManager.default.fileExists(atPath: url.path) { return try load(from: url) }
        let set = starterRuleSet
        try save(set, to: url)
        return set
    }

    /// Shipped disabled so nothing moves until the user has looked at it.
    public static var starterRuleSet: RuleSet {
        RuleSet(rules: [
            Rule(
                name: "File PDFs from Downloads by date",
                enabled: false,
                watch: ["~/Downloads"],
                conditions: [Condition(field: .kind, op: .equals, value: "pdf")],
                actions: [
                    Action(type: .rename, pattern: "{date} {name}"),
                    Action(type: .move, to: "~/Documents/FolderPilot/PDFs/{year}/{month}"),
                ]
            ),
            Rule(
                name: "Tidy old screenshots on Desktop",
                enabled: false,
                watch: ["~/Desktop"],
                conditions: [
                    Condition(field: .name, op: .startsWith, value: ["Screenshot", "Screen Shot"]),
                    Condition(field: .added, op: .olderThan, value: "7d"),
                ],
                actions: [Action(type: .move, to: "~/Pictures/Screenshots/{year}-{month}")]
            ),
        ])
    }
}

public enum RuleStoreError: LocalizedError {
    case newerVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .newerVersion(let v): return "This file uses rule format version \(v); update FolderPilot to open it."
        }
    }
}
