// Renders the 1024×1024 app icon PNG: swift Scripts/make-icon.swift out.png
import AppKit

let size = CGFloat(1024)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background squircle
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill(); shape.fill()
NSGraphicsContext.current?.restoreGraphicsState()
NSGradient(colors: [NSColor(red: 0.16, green: 0.47, blue: 0.98, alpha: 1), NSColor(red: 0.36, green: 0.27, blue: 0.93, alpha: 1)])!
    .draw(in: shape, angle: -60)

func symbol(_ name: String, points: CGFloat, color: NSColor, at center: NSPoint) {
    let config = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let tinted = NSImage(size: base.size, flipped: false) { r in
        base.draw(in: r)
        color.set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(x: center.x - base.size.width / 2, y: center.y - base.size.height / 2, width: base.size.width, height: base.size.height))
}

symbol("folder.fill", points: 430, color: .white, at: NSPoint(x: size / 2, y: size / 2 - 20))
symbol("paperplane.fill", points: 190, color: NSColor(red: 0.27, green: 0.33, blue: 0.95, alpha: 1), at: NSPoint(x: size / 2 + 10, y: size / 2 - 50))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
