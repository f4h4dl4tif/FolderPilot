import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Broad file categories used by the "Kind" condition and the `{kind}` token.
public enum FileKind: String, Codable, CaseIterable, Identifiable {
    case pdf, image, video, audio, text, document, spreadsheet, presentation, archive, application, other

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    private static let wordProcessing: [String] = [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages", "org.oasis-open.opendocument.text",
    ]

    public static func classify(_ type: UTType?) -> FileKind {
        guard let t = type else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .spreadsheet) { return .spreadsheet }
        if t.conforms(to: .presentation) { return .presentation }
        if t.conforms(to: .archive) || t.conforms(to: .diskImage) { return .archive }
        if t.conforms(to: .application) || t.conforms(to: .applicationBundle) { return .application }
        if t.conforms(to: .rtf) || t.conforms(to: .rtfd)
            || wordProcessing.contains(where: { UTType($0).map(t.conforms) ?? false }) {
            return .document
        }
        if t.conforms(to: .plainText) || t.conforms(to: .html) || t.conforms(to: .json) || t.conforms(to: .xml) { return .text }
        return .other
    }
}

/// Everything a rule can ask about one file. Expensive facts (contents, document date) are lazy.
public final class FileFacts {
    public let url: URL
    private let values: URLResourceValues?

    public init(url: URL) {
        self.url = url
        values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .creationDateKey, .contentModificationDateKey,
            .addedToDirectoryDateKey, .tagNamesKey, .contentTypeKey,
        ])
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var fullName: String { url.lastPathComponent }
    public var ext: String { url.pathExtension.lowercased() }
    public var parentName: String { url.deletingLastPathComponent().lastPathComponent }
    public var size: Int64 { Int64(values?.fileSize ?? 0) }
    public var created: Date? { values?.creationDate }
    public var modified: Date? { values?.contentModificationDate }
    public var added: Date? { values?.addedToDirectoryDate ?? created }
    public var tags: [String] { values?.tagNames ?? [] }
    public var contentType: UTType? { values?.contentType ?? UTType(filenameExtension: ext) }

    public lazy var kind: FileKind = FileKind.classify(contentType)

    /// Extracted text (PDF text layer, plain text, RTF/Word). Scanned PDFs need OCR (planned for v1.5).
    public lazy var contents: String = ContentReader.text(for: url, type: contentType)

    /// A date found in the file name, else in the first part of its contents.
    public lazy var documentDate: Date? =
        DateExtractor.firstDate(in: name) ?? DateExtractor.firstDate(in: String(contents.prefix(8000)))

    /// Date used by `{date}`, `{year}`, `{month}`, `{day}`.
    public var bestDate: Date { documentDate ?? created ?? modified ?? Date() }
}

enum ContentReader {
    static let maxCharacters = 50_000
    static let maxTextFileBytes = 4 << 20

    static func text(for url: URL, type: UTType?) -> String {
        guard let type else { return "" }
        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { return "" }
            var out = ""
            for i in 0..<min(doc.pageCount, 10) {
                out += (doc.page(at: i)?.string ?? "") + "\n"
                if out.count > maxCharacters { break }
            }
            return out
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxTextFileBytes else { return "" }
        if type.conforms(to: .plainText) || type.conforms(to: .json) || type.conforms(to: .xml) {
            if let s = try? String(contentsOf: url, encoding: .utf8) { return String(s.prefix(maxCharacters)) }
            var enc = String.Encoding.utf8
            return (try? String(contentsOf: url, usedEncoding: &enc)).map { String($0.prefix(maxCharacters)) } ?? ""
        }
        if FileKind.classify(type) == .document || type.conforms(to: .html) {
            let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
            return String((attributed?.string ?? "").prefix(maxCharacters))
        }
        return ""
    }
}

public enum DateExtractor {
    private static let isoPattern = try! NSRegularExpression(
        pattern: #"(?<!\d)((?:19|20)\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?!\d)"#)
    private static let yearPattern = try! NSRegularExpression(pattern: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#)
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Returns the earliest-positioned plausible date in the text. Requires an explicit 4-digit year,
    /// so "tomorrow" or "March 3" (no year) are ignored.
    public static func firstDate(in text: String, now: Date = Date()) -> Date? {
        guard !text.isEmpty else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let maxYear = calendar.component(.year, from: now) + 1
        var best: (location: Int, date: Date)?

        func consider(_ location: Int, _ date: Date) {
            let year = calendar.component(.year, from: date)
            guard (1990...maxYear).contains(year) else { return }
            if best == nil || location < best!.location { best = (location, date) }
        }

        for m in isoPattern.matches(in: text, range: full) {
            let parts = (1...3).map { Int(ns.substring(with: m.range(at: $0)))! }
            if let d = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) {
                consider(m.range.location, d)
            }
        }
        for m in detector.matches(in: text, range: full) {
            guard let d = m.date else { continue }
            let matched = ns.substring(with: m.range)
            guard yearPattern.firstMatch(in: matched, range: NSRange(location: 0, length: (matched as NSString).length)) != nil else { continue }
            consider(m.range.location, d)
        }
        return best?.date
    }
}
