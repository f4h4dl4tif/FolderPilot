import Foundation

/// One file-system change, with enough information to reverse it.
public struct JournalRecord: Codable, Equatable {
    public var kind: ActionType
    public var from: String
    public var to: String?
    public var previousTags: [String]?
    public var newTags: [String]?

    public var summary: String {
        let name = ((to ?? from) as NSString).lastPathComponent
        switch kind {
        case .rename: return "Renamed to \(name)"
        case .move: return "Moved to \(((to ?? "") as NSString).deletingLastPathComponent.abbreviatedPath)"
        case .copy: return "Copied to \(((to ?? "") as NSString).deletingLastPathComponent.abbreviatedPath)"
        case .tag: return "Tagged \((newTags ?? []).joined(separator: ", "))"
        case .trash: return "Moved \((from as NSString).lastPathComponent) to Trash"
        }
    }
}

public struct JournalEntry: Codable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    public var ruleName: String
    public var file: String
    public var records: [JournalRecord]
    public var error: String?
    public var undone: Bool

    public init(id: UUID = UUID(), date: Date = Date(), ruleName: String, file: String,
                records: [JournalRecord], error: String? = nil, undone: Bool = false) {
        self.id = id
        self.date = date
        self.ruleName = ruleName
        self.file = file
        self.records = records
        self.error = error
        self.undone = undone
    }

    public var fileName: String { (file as NSString).lastPathComponent }
    public var detail: String {
        var parts = records.map(\.summary)
        if let error { parts.append("Error: \(error)") }
        return parts.joined(separator: " · ")
    }
    /// Where the file ended up (for "Reveal in Finder").
    public var currentPath: String? {
        if undone { return file }
        return records.last(where: { $0.kind == .rename || $0.kind == .move })?.to ?? file
    }
    public var canUndo: Bool { !undone && !records.isEmpty }
}

/// Persistent, capped history of everything FolderPilot changed. Thread-safe.
public final class Journal {
    public let url: URL
    public let capacity: Int
    private var storage: [JournalEntry] = []
    private let lock = NSLock()

    public init(url: URL, capacity: Int = 1000) {
        self.url = url
        self.capacity = capacity
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            storage = (try? decoder.decode([JournalEntry].self, from: data)) ?? []
        }
    }

    /// Newest first.
    public var entries: [JournalEntry] {
        lock.lock(); defer { lock.unlock() }
        return storage.reversed()
    }

    public func append(_ entry: JournalEntry) {
        guard !entry.records.isEmpty || entry.error != nil else { return }
        mutate {
            $0.append(entry)
            if $0.count > capacity { $0.removeFirst($0.count - capacity) }
        }
    }

    public func markUndone(_ id: UUID) {
        mutate { list in
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].undone = true }
        }
    }

    public func clear() { mutate { $0.removeAll() } }

    private func mutate(_ change: (inout [JournalEntry]) -> Void) {
        lock.lock()
        change(&storage)
        let snapshot = storage
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(snapshot) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension String {
    var abbreviatedPath: String { (self as NSString).abbreviatingWithTildeInPath }
}
