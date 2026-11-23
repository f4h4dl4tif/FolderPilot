import SwiftUI

/// Optional Liquid Glass theme (macOS 26+). Off by default; with it off the UI is unchanged.
enum GlassTheme {
    static let key = "glassTheme"
    static var isSupported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

extension View {
    /// Sidebar status strip. Plain: the original full-width `.bar` strip. Glass: a floating glass capsule.
    @ViewBuilder
    func pilotStatusBar(glass: Bool) -> some View {
        if glass, #available(macOS 26, *) {
            self
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        } else {
            self.background(.bar)
        }
    }

    /// Secondary / prominent buttons. Plain: system default. Glass: `.glass` / `.glassProminent`.
    @ViewBuilder
    func pilotButton(glass: Bool, prominent: Bool = false) -> some View {
        if glass, #available(macOS 26, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            self
        }
    }
}
