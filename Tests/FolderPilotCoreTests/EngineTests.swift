@testable import FolderPilotCore
import XCTest

final class EngineTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("FolderPilotTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func makeFile(_ name: String, _ text: String = "hello", in folder: String = "Inbox") throws -> URL {
        let url = root.appendingPathComponent(folder).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    var inbox: String { root.appendingPathComponent("Inbox").path }

    // MARK: Format

    func testDecodesHandWrittenYAML() throws {
        let yaml = """
        version: 1
        rules:
          - name: Invoices
            watch: ~/Downloads
            conditions:
              - field: extension
                op: is
                value: [pdf, PDF]
              - field: size
                op: greaterThan
                value: 10KB
            actions:
              - type: rename
                pattern: "{date} {name}"
              - type: move
                to: ~/Documents/Finance/{year}
                onConflict: skip
        """
        let set = try RuleStore.decode(yaml)
        let rule = try XCTUnwrap(set.rules.first)
        XCTAssertEqual(rule.watch.items, ["~/Downloads"])
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.conditions[0].op, .equals)
        XCTAssertEqual(rule.conditions[0].value.items, ["pdf", "PDF"])
        XCTAssertEqual(rule.actions[1].conflictPolicy, .skip)
    }

    func testRoundTripIsStable() throws {
        let once = try RuleStore.encode(RuleStore.starterRuleSet)
        let twice = try RuleStore.encode(RuleStore.decode(once))
        XCTAssertEqual(once, twice)
    }

    func testRejectsNewerFormatVersion() {
        XCTAssertThrowsError(try RuleStore.decode("version: 99\nrules: []"))
    }

    func testValueParsers() {
        XCTAssertEqual(ValueParser.bytes("10KB"), 10240)
        XCTAssertEqual(ValueParser.bytes("1.5 MB"), 1_572_864)
        XCTAssertEqual(ValueParser.bytes("200"), 200)
        XCTAssertNil(ValueParser.bytes("big"))
        XCTAssertEqual(ValueParser.duration("7d"), 7 * 86400)
        XCTAssertEqual(ValueParser.duration("2w"), 14 * 86400)
        XCTAssertEqual(ValueParser.duration("3"), 3 * 86400)
        XCTAssertNil(ValueParser.duration("soon"))
    }

    // MARK: Extraction & templates

    func testDateExtraction() throws {
        let cal = Calendar(identifier: .gregorian)
        let iso = try XCTUnwrap(DateExtractor.firstDate(in: "Invoice_2026-03-14_final"))
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: iso), DateComponents(year: 2026, month: 3, day: 14))
        let compact = try XCTUnwrap(DateExtractor.firstDate(in: "scan20250102"))
        XCTAssertEqual(cal.component(.month, from: compact), 1)
        let prose = try XCTUnwrap(DateExtractor.firstDate(in: "Invoice date: March 3, 2025. Due April 2, 2025"))
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: prose), DateComponents(year: 2025, month: 3, day: 3))
        XCTAssertNil(DateExtractor.firstDate(in: "order 12345 tomorrow"))
        XCTAssertNil(DateExtractor.firstDate(in: "flight 1850-01-01")) // implausible year
    }

    func testTemplateRendering() throws {
        let url = try makeFile("Report 2025-11-02.txt")
        let facts = FileFacts(url: url)
        XCTAssertEqual(Template.render("{year}/{month} {monthName}/{name}.{ext}", facts: facts), "2025/11 November/Report 2025-11-02.txt")
        XCTAssertEqual(Template.render("{date:dd.MM.yy} {kind}", facts: facts), "02.11.25 text")
        XCTAssertEqual(Template.unknownTokens(in: "{name} {bogus}"), ["bogus"])
    }

    // MARK: Matching

    func testConditions() throws {
        let url = try makeFile("Invoice-ACME.txt", "Total due: 120 USD")
        let facts = FileFacts(url: url)
        let engine = Engine()
        func check(_ c: Condition) -> Bool { engine.evaluate(c, facts: facts) }
        XCTAssertTrue(check(Condition(field: .extension, op: .equals, value: [".TXT"])))
        XCTAssertTrue(check(Condition(field: .name, op: .contains, value: ["receipt", "invoice"])))
        XCTAssertFalse(check(Condition(field: .name, op: .notContains, value: "invoice")))
        XCTAssertTrue(check(Condition(field: .name, op: .matches, value: #"^invoice-\w+$"#)))
        XCTAssertTrue(check(Condition(field: .kind, op: .equals, value: "text")))
        XCTAssertTrue(check(Condition(field: .size, op: .lessThan, value: "1KB")))
        XCTAssertTrue(check(Condition(field: .contents, op: .contains, value: "total due")))
        XCTAssertTrue(check(Condition(field: .created, op: .newerThan, value: "1d")))
        XCTAssertFalse(check(Condition(field: .created, op: .olderThan, value: "1d")))
    }

    func testFirstMatchWinsAndScope() throws {
        let file = try makeFile("a.pdf")
        try makeFile("nested.pdf", in: "Inbox/Sub")
        let first = Rule(name: "First", watch: StringList([inbox]), conditions: [Condition(field: .extension, op: .equals, value: "pdf")], actions: [Action(type: .tag, tags: "A")])
        let second = Rule(name: "Second", watch: StringList([inbox]), actions: [Action(type: .tag, tags: "B")])
        XCTAssertEqual(Engine().firstMatchingRule(for: file, in: [first, second])?.name, "First")
        let nested = root.appendingPathComponent("Inbox/Sub/nested.pdf")
        XCTAssertFalse(Engine.ruleWatches(first, file: nested))
        var recursive = first
        recursive.recursive = true
        XCTAssertTrue(Engine.ruleWatches(recursive, file: nested))
    }

    // MARK: Execution

    func testRenameMoveTagThenUndo() throws {
        let original = try makeFile("invoice-2026-02-01.txt", "Invoice for services")
        let archive = root.appendingPathComponent("Archive").path
        let rule = Rule(
            name: "Invoices", watch: StringList([inbox]),
            conditions: [Condition(field: .contents, op: .contains, value: "invoice")],
            actions: [
                Action(type: .rename, pattern: "{date} Invoice"),
                Action(type: .move, to: archive + "/{year}/{month}"),
                Action(type: .tag, tags: ["Finance"]),
            ])
        let engine = Engine()
        let plans = engine.preview(rules: [rule])
        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: original.path), "preview must not touch the disk")

        let entry = engine.execute(plans[0])
        XCTAssertNil(entry.error)
        let moved = root.appendingPathComponent("Archive/2026/02/2026-02-01 Invoice.txt")
        XCTAssertTrue(fm.fileExists(atPath: moved.path))
        XCTAssertFalse(fm.fileExists(atPath: original.path))
        XCTAssertEqual(FileFacts(url: moved).tags, ["Finance"])
        XCTAssertEqual(entry.currentPath, moved.path)

        try engine.undo(entry)
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        XCTAssertFalse(fm.fileExists(atPath: moved.path))
        XCTAssertEqual(FileFacts(url: original).tags, [])
    }

    func testConflictPolicies() throws {
        try makeFile("doc.txt", "new")
        try makeFile("doc.txt", "existing", in: "Out")
        let out = root.appendingPathComponent("Out").path
        let engine = Engine()

        let keepBoth = Rule(name: "k", watch: StringList([inbox]), actions: [Action(type: .copy, to: out)])
        let plan = try XCTUnwrap(engine.preview(rules: [keepBoth]).first)
        XCTAssertEqual(plan.operations.first?.destination?.lastPathComponent, "doc 2.txt")

        let skip = Rule(name: "s", watch: StringList([inbox]), actions: [Action(type: .move, to: out, onConflict: .skip), Action(type: .tag, tags: "X")])
        let skipped = try XCTUnwrap(engine.preview(rules: [skip]).first)
        XCTAssertTrue(skipped.operations.isEmpty)
        XCTAssertNotNil(skipped.note)
    }

    func testBatchReservesNamesWithinOnePreview() throws {
        try makeFile("a.txt", in: "Inbox")
        try makeFile("b.txt", in: "Inbox")
        let rule = Rule(name: "same", watch: StringList([inbox]), actions: [Action(type: .rename, pattern: "Same")])
        let names = Engine().preview(rules: [rule]).compactMap { $0.operations.first?.destination?.lastPathComponent }
        XCTAssertEqual(Set(names), ["Same.txt", "Same 2.txt"])
    }

    func testRelativeDestinationAndNoOpRename() throws {
        try makeFile("x.txt")
        let rule = Rule(name: "r", watch: StringList([inbox]), actions: [Action(type: .rename, pattern: "{name}"), Action(type: .move, to: "Done")])
        let plan = try XCTUnwrap(Engine().preview(rules: [rule]).first)
        XCTAssertEqual(plan.operations.map(\.kind), [.move])
        XCTAssertEqual(plan.finalURL.deletingLastPathComponent().lastPathComponent, "Done")
    }

    // MARK: Live watching

    func testServiceProcessesNewFiles() throws {
        let journal = Journal(url: root.appendingPathComponent("journal.json"))
        let service = AutomationService(journal: journal)
        service.settleTicks = 1
        let rule = Rule(name: "Live", watch: StringList([inbox]),
                        conditions: [Condition(field: .extension, op: .equals, value: "txt")],
                        actions: [Action(type: .move, to: root.appendingPathComponent("Sorted").path)])
        let done = expectation(description: "processed")
        service.onEvent = { if case .processed = $0 { done.fulfill() } }
        service.update(rules: [rule])
        service.start()
        Thread.sleep(forTimeInterval: 1.0) // let FSEvents start
        try makeFile("arrived.txt")
        wait(for: [done], timeout: 15)
        service.stop()
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Sorted/arrived.txt").path))
        XCTAssertEqual(journal.entries.count, 1)
    }
}
