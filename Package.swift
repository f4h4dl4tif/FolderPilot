// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FolderPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FolderPilot", targets: ["FolderPilot"]),
        .executable(name: "fpilot", targets: ["fpilot"]),
        .library(name: "FolderPilotCore", targets: ["FolderPilotCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Platform-neutral-ish rule engine: models, YAML store, matching, templates, execution, journal, watcher.
        .target(name: "FolderPilotCore", dependencies: ["Yams"]),
        // SwiftUI menu-bar + window app.
        .executableTarget(name: "FolderPilot", dependencies: ["FolderPilotCore"]),
        // Command-line companion: validate / preview / run rule files.
        .executableTarget(name: "fpilot", dependencies: ["FolderPilotCore"]),
        .testTarget(name: "FolderPilotCoreTests", dependencies: ["FolderPilotCore"]),
    ]
)
