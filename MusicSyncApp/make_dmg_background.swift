// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
// Disegna lo sfondo della finestra del DMG con la freccia "trascina in Applicazioni".
// Uso: swift make_dmg_background.swift <out.png> <scala>
//
// L'immagine è più alta della finestra (vedi dist/dmg_settings.py): se il Finder
// mostra barre in più o in meno, sotto resta comunque sfondo e non bianco.
// Le posizioni delle icone in dmg_settings.py devono restare allineate a queste.
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "bg.png"
let scale: CGFloat = args.count > 2 ? CGFloat(Double(args[2]) ?? 1) : 1
let w: CGFloat = 640, h: CGFloat = 560

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale),
                           pixelsHigh: Int(h * scale), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// sfondo chiaro con una sfumatura nei colori dell'icona
NSGradient(colors: [
    NSColor(red: 1.00, green: 0.96, blue: 0.97, alpha: 1),
    NSColor(red: 0.98, green: 0.90, blue: 0.94, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

let accent = NSColor(red: 0.80, green: 0.08, blue: 0.30, alpha: 1)

/// y misurata dall'alto, come le coordinate del Finder.
func text(_ s: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .paragraphStyle: style,
    ]
    let lineH = size * 1.5
    NSAttributedString(string: s, attributes: attrs)
        .draw(in: NSRect(x: 0, y: h - top - lineH, width: w, height: lineH))
}

text("Trascina Music Sync nella cartella Applicazioni", top: 28, size: 18,
     weight: .semibold, color: accent)

// freccia tra le due icone (centri a x=160 e x=480, y=150 dall'alto)
let y = h - 150
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 245, y: y))
arrow.line(to: NSPoint(x: 385, y: y))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
accent.withAlphaComponent(0.75).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 398, y: y))
head.line(to: NSPoint(x: 376, y: y + 15))
head.line(to: NSPoint(x: 376, y: y - 15))
head.close()
accent.withAlphaComponent(0.75).setFill()
head.fill()

// sotto il Leggimi (icona a y=300, etichetta fino a ~370)
text("Prima di aprire l'app la prima volta leggi il Leggimi", top: 382, size: 12,
     weight: .regular, color: NSColor(white: 0.45, alpha: 1))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
