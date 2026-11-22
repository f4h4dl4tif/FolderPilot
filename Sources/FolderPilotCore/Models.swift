import Foundation

// MARK: - Rule set (the on-disk, shareable format)

/// Top-level document stored in `rules.yaml` and in shareable `.folderpilot` files.
/// The schema is versioned so the marketplace and a future Windows edition can read it.
public struct RuleSet: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var rules: [Rule]

    public init(version: Int = RuleSet.currentVersion, rules: [Rule] = []) {
        self.version = version
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? RuleSet.currentVersion
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }
}

public enum MatchMode: String, Codable, CaseIterable, Identifiable {
    case all, any
    public var id: String { rawValue }
    public var label: String { self == .all ? "All conditions" : "Any condition" }
}

public struct Rule: Codable, Equatable, Identifiable {
    public var name: String
    public var enabled: Bool
    /// Folders this rule watches. `~` is allowed. A single string or a list in YAML.
    public var watch: StringList
    public var recursive: Bool
    public var match: MatchMode
    public var conditions: [Condition]
    public var actions: [Action]
    public var id: UUID

    public init(
        id: UUID = UUID(), name: String, enabled: Bool = true, watch: StringList = [],
        recursive: Bool = false, match: MatchMode = .all,
        conditions: [Condition] = [], actions: [Action] = []
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.watch = watch
        self.recursive = recursive
        self.match = match
        self.conditions = conditions
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey {
        case name, enabled, watch, recursive, match, conditions, actions, id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Rule"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        watch = try c.decodeIfPresent(StringList.self, forKey: .watch) ?? []
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        match = try c.decodeIfPresent(MatchMode.self, forKey: .match) ?? .all
        conditions = try c.decodeIfPresent([Condition].self, forKey: .conditions) ?? []
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
    }

    /// Human-readable problems that would stop the rule from working as intended.
    public func validate() -> [String] {
        var issues: [String] = []
        if watch.items.isEmpty { issues.append("Choose at least one folder to watch.") }
        for folder in watch.items {
            var isDir: ObjCBool = false
            let path = (folder as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
                issues.append("Watched folder does not exist: \(folder)")
            }
        }
        if actions.isEmpty { issues.append("Add at least one action.") }
        for condition in conditions { issues.append(contentsOf: condition.validate()) }
        for action in actions { issues.append(contentsOf: action.validate()) }
        return issues
    }
}

// MARK: - Conditions

public enum Field: String, Codable, CaseIterable, Identifiable {
    case name, fullName, `extension`, kind, size, created, modified, added, contents, tags

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .name: return "Name"
        case .fullName: return "Full name"
        case .extension: return "Extension"
        case .kind: return "Kind"
        case .size: return "Size"
        case .created: return "Date created"
        case .modified: return "Date modified"
        case .added: return "Date added"
        case .contents: return "Contents"
        case .tags: return "Tags"
        }
    }

    public var operators: [Op] {
        switch self {
        case .name, .fullName: return [.contains, .notContains, .equals, .notEquals, .startsWith, .endsWith, .matches]
        case .extension, .kind: return [.equals, .notEquals]
        case .size: return [.greaterThan, .lessThan]
        case .created, .modified, .added: return [.olderThan, .newerThan]
        case .contents: return [.contains, .notContains, .matches]
        case .tags: return [.contains, .notContains]
        }
    }

    public var placeholder: String {
        switch self {
        case .name, .fullName: return "invoice, receipt"
        case .extension: return "pdf, jpg"
        case .kind: return "pdf"
        case .size: return "10 MB"
        case .created, .modified, .added: return "7d  (h, d, w, m, y)"
        case .contents: return "Invoice"
        case .tags: return "Finance"
        }
    }
}

public enum Op: String, Codable, CaseIterable, Identifiable {
    case equals = "is"
    case notEquals = "isNot"
    case contains, notContains, startsWith, endsWith, matches
    case greaterThan, lessThan, olderThan, newerThan

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .equals: return "is"
        case .notEquals: return "is not"
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .matches: return "matches regex"
        case .greaterThan: return "is greater than"
        case .lessThan: return "is less than"
        case .olderThan: return "is older than"
        case .newerThan: return "is within the last"
        }
    }
}

public struct Condition: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var field: Field
    public var op: Op
    /// One value or a list (list means "any of these" for positive operators, "none of these" for negative ones).
    public var value: StringList

    public init(field: Field, op: Op, value: StringList) {
        self.field = field
        self.op = op
        self.value = value
    }

    enum CodingKeys: String, CodingKey { case field, op, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(Field.self, forKey: .field)
        op = try c.decodeIfPresent(Op.self, forKey: .op) ?? field.operators[0]
        value = try c.decodeIfPresent(StringList.self, forKey: .value) ?? []
    }

    public func validate() -> [String] {
        var issues: [String] = []
        if !field.operators.contains(op) {
            issues.append("\(field.label) can't use “\(op.label)”.")
        }
        if value.items.isEmpty { issues.append("\(field.label) condition needs a value.") }
        for v in value.items {
            if op == .matches, (try? NSRegularExpression(pattern: v)) == nil {
                issues.append("Invalid regular expression: \(v)")
            }
            if [.greaterThan, .lessThan].contains(op), ValueParser.bytes(v) == nil {
                issues.append("Can't read size “\(v)”. Try 10 MB.")
            }
            if [.olderThan, .newerThan].contains(op), ValueParser.duration(v) == nil {
                issues.append("Can't read duration “\(v)”. Try 7d or 2w.")
            }
            if field == .kind, FileKind(rawValue: v.lowercased()) == nil {
                issues.append("Unknown kind “\(v)”.")
            }
        }
        return issues
    }
}

// MARK: - Actions

public enum ActionType: String, Codable, CaseIterable, Identifiable {
    case rename, move, copy, tag, trash
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rename: return "Rename"
        case .move: return "Move to folder"
        case .copy: return "Copy to folder"
        case .tag: return "Add tags"
        case .trash: return "Move to Trash"
        }
    }

    public var symbol: String {
        switch self {
        case .rename: return "pencil"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        case .tag: return "tag"
        case .trash: return "trash"
        }
    }
}

public enum ConflictPolicy: String, Codable, CaseIterable, Identifiable {
    /// Append " 2", " 3"… until the name is free.
    case rename
    case skip
    /// Moves the existing file to the Trash first, so it can still be recovered.
    case overwrite
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .rename: return "Keep both"
        case .skip: return "Skip"
        case .overwrite: return "Replace (old file to Trash)"
        }
    }
}

public struct Action: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var type: ActionType
    /// Destination folder template for move/copy. Absolute, `~/…`, or relative to the file's folder.
    public var to: String?
    /// New-name template for rename. The extension is kept unless the pattern includes `{ext}`.
    public var pattern: String?
    public var tags: StringList?
    public var onConflict: ConflictPolicy?

    public init(type: ActionType, to: String? = nil, pattern: String? = nil, tags: StringList? = nil, onConflict: ConflictPolicy? = nil) {
        self.type = type
        self.to = to
        self.pattern = pattern
        self.tags = tags
        self.onConflict = onConflict
    }

    enum CodingKeys: String, CodingKey { case type, to, pattern, tags, onConflict }

    public var conflictPolicy: ConflictPolicy { onConflict ?? .rename }

    public func validate() -> [String] {
        var issues: [String] = []
        switch type {
        case .rename:
            let p = pattern ?? ""
            if p.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("Rename needs a name pattern.") }
            issues += Template.unknownTokens(in: p).map { "Unknown token {\($0)} in rename pattern." }
        case .move, .copy:
            let t = to ?? ""
            if t.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("\(type.label) needs a destination.") }
            issues += Template.unknownTokens(in: t).map { "Unknown token {\($0)} in destination." }
        case .tag:
            if (tags?.items ?? []).isEmpty { issues.append("Add tags needs at least one tag.") }
        case .trash:
            break
        }
        return issues
    }
}

// MARK: - Helpers

/// Decodes from either a YAML scalar or a sequence; encodes a single item as a scalar.
public struct StringList: Codable, Equatable, Hashable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    public var items: [String]

    public init(_ items: [String]) { self.items = items }
    public init(stringLiteral value: String) { items = [value] }
    public init(arrayLiteral elements: String...) { items = elements }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { items = []; return }
        if let list = try? c.decode([String].self) { items = list; return }
        if let s = try? c.decode(String.self) { items = [s]; return }
        if let i = try? c.decode(Int.self) { items = [String(i)]; return }
        if let d = try? c.decode(Double.self) { items = [String(d)]; return }
        throw DecodingError.typeMismatch(StringList.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected a string or a list of strings"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if items.count == 1 { try c.encode(items[0]) } else { try c.encode(items) }
    }

    /// Comma-separated form used by text fields in the UI.
    public var text: String {
        get { items.joined(separator: ", ") }
        set {
            items = newValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

public enum ValueParser {
    /// "10KB", "1.5 MB", "200" (bytes). Uses 1024-based units, like Finder's "KB" in most users' heads.
    public static func bytes(_ raw: String) -> Int64? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("tb", 1_099_511_627_776), ("gb", 1_073_741_824), ("mb", 1_048_576), ("kb", 1024), ("b", 1)]
        for (suffix, multiplier) in units where s.hasSuffix(suffix) {
            let number = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let n = Double(number), n >= 0 else { return nil }
            return Int64(n * multiplier)
        }
        guard let n = Double(s), n >= 0 else { return nil }
        return Int64(n)
    }

    /// "12h", "7d", "2w", "3m" (months of 30 days), "1y". A bare number means days.
    public static func duration(_ raw: String) -> TimeInterval? {
        let s = raw.replacingOccurrences(of: " ", with: "").lowercased()
        let hour = 3600.0, day = 86400.0
        let units: [(String, Double)] = [("h", hour), ("d", day), ("w", 7 * day), ("m", 30 * day), ("y", 365 * day)]
        for (suffix, multiplier) in units where s.hasSuffix(suffix) {
            guard let n = Double(s.dropLast()), n >= 0 else { return nil }
            return n * multiplier
        }
        guard let n = Double(s), n >= 0 else { return nil }
        return n * day
    }
}
