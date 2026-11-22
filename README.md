# FolderPilot

A free, open-source, rule-based file workflow engine for macOS.

> Every time a PDF lands in Downloads, read its invoice date, rename it `2026-03-03 Invoice …`, tag it *Finance*, and file it under `Finance/2026/03`.

## Features (MVP)

- **Folder monitoring**: FSEvents-based. FolderPilot waits until a file stops changing (finished downloads/copies) and ignores browser temp files.
- **Rules**: conditions on name, extension, kind, size, created/modified/added date, **contents** (PDF text, plain text, RTF/Word) and tags. Match *all* or *any*.
- **Actions**: rename, move, copy, add Finder tags, move to Trash. Actions run in order.
- **Date extraction**: `{date}` uses a date found in the file name, then inside the document, then the creation date.
- **Batch operations**: *Preview & Run* dry-runs a rule over files already in its folders. You review every change, untick any you don't want, then apply.
- **Undo**: every change is journaled. Undo any entry from Activity or the menu bar.
- **Menu bar app**: keeps working after the window closes. Pause/resume, run all, undo last.
- **Plain YAML rules**: `~/Library/Application Support/FolderPilot/rules.yaml`. Share rules as `.folderpilot` files (Rules ▸ Export / Import). Imported rules arrive **disabled** until reviewed.
- **`fpilot` CLI**: `validate`, `preview`, `run --yes`.

## Build

Requires macOS 14+ and Xcode installed (the Command Line Tools alone lack SwiftUI's macro plugin).

```bash
./build.sh                 # → build/FolderPilot.app and build/fpilot
UNIVERSAL=1 ./build.sh     # Apple Silicon + Intel
cp -R build/FolderPilot.app /Applications/
```

Tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Rule format

```yaml
version: 1
rules:
- name: Freelancer invoices
  enabled: true
  watch: ~/Downloads            # one folder or a list
  recursive: false              # include subfolders
  match: all                    # all | any
  conditions:
  - { field: kind, op: is, value: pdf }
  - { field: contents, op: contains, value: [invoice, bill to] }   # list = any of these
  actions:
  - { type: rename, pattern: "{date} Invoice {name}" }             # extension kept automatically
  - { type: move, to: "~/Documents/Finance/{year}/{month}", onConflict: rename }
  - { type: tag, tags: [Finance] }
```

| Field | Operators | Value examples |
|---|---|---|
| `name`, `fullName` | `is` `isNot` `contains` `notContains` `startsWith` `endsWith` `matches` | `invoice`, regex |
| `extension` | `is` `isNot` | `pdf`, `[jpg, png]` |
| `kind` | `is` `isNot` | `pdf image video audio text document spreadsheet presentation archive application other` |
| `size` | `greaterThan` `lessThan` | `10 MB`, `500KB` |
| `created` `modified` `added` | `olderThan` `newerThan` | `12h` `7d` `2w` `3m` `1y` |
| `contents` | `contains` `notContains` `matches` | `Invoice` |
| `tags` | `contains` `notContains` | `Finance` |

**Tokens** (rename patterns and destinations): `{name}` `{ext}` `{kind}` `{parent}` `{date}` `{date:dd MMM yyyy}` `{year}` `{month}` `{monthName}` `{day}` `{created}` `{modified}` `{added}` `{now}`. Destinations can be absolute, `~/…`, or relative to the file's folder (`Sorted/{kind}`).

**Conflicts**: `rename` (keep both, default), `skip`, `overwrite` (old file goes to the Trash).

**Order**: for each file, the first enabled rule (top to bottom) whose folder and conditions match wins.

See [`Examples/`](Examples) for ready-made workflows.

## Architecture

```
Sources/
  FolderPilotCore/      # UI-free engine, shared by app, CLI and (future) other front ends
    Models.swift        # RuleSet / Rule / Condition / Action, versioned YAML schema
    RuleStore.swift     # YAML load/save, starter rules
    FileFacts.swift     # file metadata, kind classification, content text, date extraction
    Template.swift      # {token} rendering and path resolution
    Engine.swift        # matching, dry-run planning, conflict resolution, execution, undo
    Journal.swift       # persistent history for undo/activity
    FolderWatcher.swift # FSEvents wrapper
    AutomationService.swift  # watcher → settle → match → execute → journal; loop protection
  FolderPilot/          # SwiftUI app (window + menu bar + settings)
  fpilot/               # CLI
```

## Roadmap

- **v1.5**: OCR for scanned PDFs/images (Vision), field extraction (amount, vendor, invoice #), Finder Quick Action, PDF tools, Shortcuts/App Intents.
- **v2.0**: natural-language rule creation (on-device), GitHub-hosted workflow marketplace, starter packs.
- **v2.5**: plugin SDK (WebAssembly), integrations (cloud folders, Paperless-ngx, Obsidian, webhooks).
- **v3.0**: Windows edition sharing the same rule format.

## License

MIT
