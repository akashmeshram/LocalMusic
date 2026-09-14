// Renders the LocalMusic app icon at all macOS sizes and packs an .icns.
// Usage: swiftc -O Scripts/make-icon.swift -o build/make-icon && build/make-icon Sources/LocalMusic/Resources/AppIcon.icns
import AppKit

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    let s = size / 1024
    // macOS icon grid: 824pt rounded square centered on a 1024 canvas.
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = 824 * 0.2237 * s
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.30, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(calibratedRed: 0.15, green: 0.12, blue: 0.42, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.85, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.86, green: 0.30, blue: 0.62, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.62, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Soft highlight top-left
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22), startRadius: 0,
                           endCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22), endRadius: rect.width * 0.75, options: [])

    // Vinyl disc: dark disc with faint grooves, offset slightly left
    let center = CGPoint(x: rect.midX - 20 * s, y: rect.midY + 10 * s)
    let discR = 300 * s
    ctx.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 0.92).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - discR, y: center.y - discR, width: discR * 2, height: discR * 2))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(2.5 * s)
    for r in stride(from: discR * 0.42, through: discR * 0.95, by: discR * 0.075) {
        ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }
    // Sheen on the disc
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - discR, y: center.y - discR, width: discR * 2, height: discR * 2)); ctx.clip()
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: center.x - discR, y: center.y + discR), end: CGPoint(x: center.x + discR * 0.2, y: center.y - discR * 0.2), options: [])
    ctx.restoreGState()
    // Label
    let labelR = discR * 0.36
    ctx.setFillColor(NSColor(calibratedRed: 0.98, green: 0.45, blue: 0.55, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - labelR, y: center.y - labelR, width: labelR * 2, height: labelR * 2))
    ctx.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - 14 * s, y: center.y - 14 * s, width: 28 * s, height: 28 * s))
    ctx.restoreGState()

    // Music note (SF Symbol) in white with a shadow, overlapping the disc
    if let symbol = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 420 * s, weight: .bold)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let noteRect = CGRect(x: rect.midX - tinted.size.width / 2 + 120 * s, y: rect.midY - tinted.size.height / 2 - 10 * s,
                              width: tinted.size.width, height: tinted.size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        tinted.draw(in: noteRect, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()
    }

    // Download badge, bottom-right
    let badgeR = 92 * s
    let badgeCenter = CGPoint(x: rect.maxX - 150 * s, y: rect.minY + 150 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4 * s), blur: 10 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: badgeCenter.x - badgeR, y: badgeCenter.y - badgeR, width: badgeR * 2, height: badgeR * 2))
    ctx.restoreGState()
    if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 100 * s, weight: .heavy)) {
        let tinted = NSImage(size: arrow.size, flipped: false) { r in
            arrow.draw(in: r)
            NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.85, alpha: 1).set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: badgeCenter.x - tinted.size.width / 2, y: badgeCenter.y - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = draw(size: 1024)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try png(draw(size: CGFloat(px)), pixels: px).write(to: iconset.appendingPathComponent(name + ".png"))
}
try png(master, pixels: 1024).write(to: output.deletingLastPathComponent().appendingPathComponent("AppIcon-preview.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
