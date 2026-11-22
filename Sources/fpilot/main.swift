import FolderPilotCore
import Foundation

// fpilot — command-line companion to FolderPilot.
//   fpilot validate [FILE]
//   fpilot preview  [FILE] [--rule NAME]
//   fpilot run      [FILE] [--rule NAME] [--yes]
// FILE defaults to the app's rules.yaml. `run` without --yes only previews.

let usage = """
usage: fpilot <validate|preview|run> [rules.yaml] [--rule NAME] [--yes]
  validate   check a rules file for problems
  preview    show what rules would do to files already in their folders (no changes)
  run        apply those changes (requires --yes; recorded in the app's Activity history)
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["validate", "preview", "run"].contains(command) else {
    print(usage)
    exit(args.isEmpty || args.first == "--help" ? 0 : 64)
}
args.removeFirst()

var ruleName: String?
var confirmed = false
var file: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--rule": ruleName = args.isEmpty ? nil : args.removeFirst()
    case "--yes", "-y": confirmed = true
    default: file = a
    }
}

let url = file.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? RuleStore.defaultRulesURL
let set: RuleSet
do {
    set = try RuleStore.load(from: url)
} catch {
    FileHandle.standardError.write("error: \(url.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}

var rules = set.rules
if let ruleName {
    rules = rules.filter { $0.name.caseInsensitiveCompare(ruleName) == .orderedSame }
    if rules.isEmpty {
        FileHandle.standardError.write("error: no rule named “\(ruleName)”\n".data(using: .utf8)!)
        exit(1)
    }
} else if command != "validate" {
    rules = rules.filter(\.enabled)
}

switch command {
case "validate":
    var problems = 0
    for rule in rules {
        let issues = rule.validate()
        print("\(issues.isEmpty ? "✓" : "✗") \(rule.name)\(rule.enabled ? "" : " (disabled)")")
        for i in issues { print("    - \(i)") }
        problems += issues.count
    }
    exit(problems == 0 ? 0 : 2)

default:
    let engine = Engine()
    let plans = engine.preview(rules: rules)
    if plans.isEmpty { print("No matching files."); exit(0) }
    for p in plans { print("• \(p.file.lastPathComponent)  [\(p.ruleName)]\n    \(p.summary)") }
    guard command == "run" else { exit(0) }
    guard confirmed else {
        print("\n\(plans.count) file(s) would change. Re-run with --yes to apply.")
        exit(0)
    }
    let journal = Journal(url: RuleStore.defaultJournalURL)
    var failures = 0
    for p in plans where !p.operations.isEmpty {
        let entry = engine.execute(p)
        journal.append(entry)
        if let e = entry.error { failures += 1; print("✗ \(p.file.lastPathComponent): \(e)") }
    }
    print("\nApplied \(plans.count - failures) plan(s)\(failures > 0 ? ", \(failures) failed" : "").")
    exit(failures == 0 ? 0 : 1)
}
