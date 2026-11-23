import AppKit
import SwiftUI

/// Developer aid: `--glass-snapshot <dir>` (DEBUG builds only) captures each screen with the
/// Liquid Glass theme off and on, in light and dark, then quits. It restores the saved setting.
@MainActor
enum GlassSnapshot {
    static var directory: String? {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--glass-snapshot"), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }
    nonisolated static var isRequested: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--glass-snapshot")
        #else
        return false
        #endif
    }

    static func runIfRequested() {
        #if DEBUG
        guard let dir = directory else { return }
        run(dir)
        #endif
    }

    #if DEBUG
    private typealias CapFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Captures a window as it is on screen (real Liquid Glass; cacheDisplay doesn't render glass).
    static func capture(_ window: NSWindow, to path: String) {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
        let f = unsafeBitCast(sym, to: CapFn.self)
        guard let img = f(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    private static func run(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: GlassTheme.key)
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func mainWindow() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
                ?? NSApp.windows.filter { $0.isVisible && $0.frame.width > 700 }.max { $0.frame.width < $1.frame.width }
        }
        func shoot(_ name: String, window: () -> NSWindow?) async {
            for glass in [false, true] {
                defaults.set(glass, forKey: GlassTheme.key)
                for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    NSApp.appearance = NSAppearance(named: appearance)
                    NSApp.activate(ignoringOtherApps: true)
                    await sleep(1.2)
                    if let w = window() { capture(w, to: "\(dir)/\(name)-\(glass ? "glass" : "plain")-\(mode).png") }
                }
            }
        }
        Task { @MainActor in
            await sleep(2)
            guard let model = AppModel.current else { NSApp.terminate(nil); return }
            mainWindow()?.setContentSize(NSSize(width: 1100, height: 700))
            mainWindow()?.center()
            if let first = model.ruleSet.rules.first { model.selection = .rule(first.id) }
            await sleep(1)
            await shoot("main", window: mainWindow)
            model.selection = .activity
            await sleep(1)
            await shoot("activity", window: mainWindow)
            model.requestPreview(of: model.ruleSet.rules, title: "All rules")
            await sleep(3)
            await shoot("preview", window: { mainWindow()?.attachedSheet })
            model.previewRequest = nil
            await sleep(1)
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
               let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            await sleep(1.5)
            await shoot("settings", window: { NSApp.windows.first { $0.isVisible && $0.title.hasSuffix("Settings") } })
            if let original { defaults.set(original, forKey: GlassTheme.key) } else { defaults.removeObject(forKey: GlassTheme.key) }
            NSApp.appearance = nil
            exit(0)
        }
    }
    #endif
}
