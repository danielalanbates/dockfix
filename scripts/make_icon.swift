// Draws the DockFix app icon into an .iconset folder; build.sh turns it into AppIcon.icns.
// Usage: swift make_icon.swift <output.iconset>
// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved. See LICENSE.

import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func tinted(_ symbol: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    else { return nil }
    return NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Body on Apple's macOS icon grid: 824/1024 with rounded corners.
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.44, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.07, green: 0.72, blue: 0.82, alpha: 1)])!.draw(in: shape, angle: -90)

    // The Dock shelf.
    let shelf = NSRect(x: body.minX + body.width * 0.10, y: body.minY + body.height * 0.13,
                       width: body.width * 0.80, height: body.height * 0.13)
    NSColor(white: 1, alpha: 0.30).setFill()
    NSBezierPath(roundedRect: shelf, xRadius: shelf.height * 0.35, yRadius: shelf.height * 0.35).fill()

    // Two plain tiles and a big repaired one in the middle.
    let small = body.width * 0.17
    let big = body.width * 0.40
    let baseY = shelf.minY + shelf.height * 0.30
    for x in [body.minX + body.width * 0.15, body.maxX - body.width * 0.15 - small] {
        let tile = NSRect(x: x, y: baseY, width: small, height: small)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: tile, xRadius: small * 0.24, yRadius: small * 0.24).fill()
    }
    let center = NSRect(x: body.midX - big / 2, y: baseY, width: big, height: big)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.03
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: center, xRadius: big * 0.24, yRadius: big * 0.24).fill()
    NSGraphicsContext.restoreGraphicsState()

    if let wrench = tinted("wrench.adjustable.fill", pointSize: big * 0.55,
                           color: NSColor(srgbRed: 0.13, green: 0.40, blue: 0.95, alpha: 1)) {
        let scale = min(big * 0.62 / wrench.size.width, big * 0.62 / wrench.size.height)
        let w = wrench.size.width * scale, h = wrench.size.height * scale
        wrench.draw(in: NSRect(x: center.midX - w / 2, y: center.midY - h / 2, width: w, height: h))
    }

    // Running-app dot under the repaired tile.
    let dot = size * 0.022
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: body.midX - dot / 2, y: shelf.minY + shelf.height * 0.08, width: dot, height: dot)).fill()

    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                       ("512x512@2x", 1024)] {
    try render(pixels: pixels).write(to: output.appendingPathComponent("icon_\(name).png"))
}
