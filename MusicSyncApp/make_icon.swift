// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
// Disegna l'icona dell'app (1024x1024) e la salva come PNG.
// Uso: swift make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// sfondo: squircle della griglia icone macOS (824pt, margine 100)
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(colors: [
    NSColor(red: 1.00, green: 0.33, blue: 0.42, alpha: 1),
    NSColor(red: 0.80, green: 0.08, blue: 0.30, alpha: 1),
    NSColor(red: 0.45, green: 0.05, blue: 0.35, alpha: 1),
])!
gradient.draw(in: shape, angle: -70)

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(.init(paletteColors: [.white]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
}

func draw(_ img: NSImage, center: NSPoint, alpha: CGFloat = 1) {
    let s = img.size
    img.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2,
                        width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: alpha)
}

let c = NSPoint(x: size / 2, y: size / 2)
draw(symbol("arrow.triangle.2.circlepath", pointSize: 520, weight: .semibold), center: c, alpha: 0.35)
draw(symbol("music.note", pointSize: 330, weight: .bold), center: NSPoint(x: c.x - 10, y: c.y))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
