import Foundation

/// Renders `{token}` / `{token:format}` placeholders in rename patterns and destination paths.
public enum Template {
    public struct Token: Identifiable {
        public let token: String
        public let help: String
        public var id: String { token }
    }

    public static let tokens: [Token] = [
        Token(token: "{name}", help: "File name without extension"),
        Token(token: "{ext}", help: "Extension"),
        Token(token: "{kind}", help: "pdf, image, document…"),
        Token(token: "{date}", help: "Document date (from name or contents), else created — yyyy-MM-dd"),
        Token(token: "{date:dd MMM yyyy}", help: "Document date, custom format"),
        Token(token: "{year}", help: "Year of document date"),
        Token(token: "{month}", help: "Month number of document date"),
        Token(token: "{monthName}", help: "Month name of document date"),
        Token(token: "{day}", help: "Day of document date"),
        Token(token: "{created}", help: "Date created"),
        Token(token: "{modified}", help: "Date modified"),
        Token(token: "{added}", help: "Date added to folder"),
        Token(token: "{now}", help: "Today"),
        Token(token: "{parent}", help: "Current folder name"),
    ]

    static let knownNames: Set<String> = [
        "name", "ext", "kind", "date", "year", "month", "monthName", "day",
        "created", "modified", "added", "now", "parent",
    ]

    private static let pattern = try! NSRegularExpression(pattern: #"\{([A-Za-z]+)(?::([^}]*))?\}"#)

    public static func unknownTokens(in template: String) -> [String] {
        let ns = template as NSString
        return pattern.matches(in: template, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { !knownNames.contains($0) }
    }

    public static func render(_ template: String, facts: FileFacts, now: Date = Date()) -> String {
        let ns = template as NSString
        var result = ""
        var cursor = 0
        for m in pattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let name = ns.substring(with: m.range(at: 1))
            let format = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            if let value = value(for: name, format: format, facts: facts, now: now) {
                result += sanitize(value)
            } else {
                result += ns.substring(with: m.range)
            }
            cursor = m.range.location + m.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func value(for token: String, format: String?, facts: FileFacts, now: Date) -> String? {
        switch token {
        case "name": return facts.name
        case "ext": return facts.url.pathExtension
        case "kind": return facts.kind.rawValue
        case "parent": return facts.parentName
        case "date": return formatted(facts.bestDate, format ?? "yyyy-MM-dd")
        case "year": return formatted(facts.bestDate, "yyyy")
        case "month": return formatted(facts.bestDate, "MM")
        case "monthName": return formatted(facts.bestDate, "MMMM")
        case "day": return formatted(facts.bestDate, "dd")
        case "created": return formatted(facts.created ?? now, format ?? "yyyy-MM-dd")
        case "modified": return formatted(facts.modified ?? now, format ?? "yyyy-MM-dd")
        case "added": return formatted(facts.added ?? now, format ?? "yyyy-MM-dd")
        case "now": return formatted(now, format ?? "yyyy-MM-dd")
        default: return nil
        }
    }

    /// Always Gregorian + POSIX so `{year}` is 2026 regardless of the user's calendar settings.
    private static func formatted(_ date: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = format
        return f.string(from: date)
    }

    /// Token values must not introduce path separators.
    static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Expands `~`, and resolves relative paths against `base`.
    public static func resolvePath(_ rendered: String, relativeTo base: URL) -> URL {
        let expanded = (rendered.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL }
        return base.appendingPathComponent(expanded, isDirectory: true).standardizedFileURL
    }
}
