#!/usr/bin/env swift
// Genere Packaging/AppIcon.iconset (puis iconutil en fait AppIcon.icns).
// Chaque taille est dessinee vectoriellement pour rester nette a 16 points.
//
// Motif : un ecran sombre de moniteur portant une courbe de charge au degrade
// vert, jaune, rouge de btop, et trois jauges en dessous.

import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let backgroundTop = rgb(44, 50, 62)
let backgroundBottom = rgb(14, 17, 24)
let gridColor = rgb(255, 255, 255, 0.08)
let loadGradient = NSGradient(colors: [rgb(52, 199, 89), rgb(255, 214, 10), rgb(255, 149, 0), rgb(255, 59, 48)])!

/// Courbe de charge, en coordonnees normalisees (0...1).
let samples: [CGFloat] = [0.18, 0.26, 0.22, 0.38, 0.33, 0.52, 0.45, 0.70, 0.58, 0.86, 0.66, 0.74]
let compactSamples: [CGFloat] = [0.2, 0.35, 0.3, 0.6, 0.5, 0.85, 0.65]

func draw(size: CGFloat) {
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let compact = size <= 32

    // Grille d'icone macOS : carre arrondi de 824 points centre.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0, 0, 0, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    backgroundBottom.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: backgroundTop, ending: backgroundBottom)!.draw(in: tilePath, angle: -90)

    // Zone du graphe.
    let graph = compact ? NSRect(x: 190, y: 360, width: 644, height: 430)
                        : NSRect(x: 180, y: 400, width: 664, height: 410)
    if !compact {
        gridColor.setStroke()
        for step in 1..<4 {
            let line = NSBezierPath()
            let y = graph.minY + graph.height * CGFloat(step) / 4
            line.move(to: NSPoint(x: graph.minX, y: y))
            line.line(to: NSPoint(x: graph.maxX, y: y))
            line.lineWidth = 6
            line.stroke()
        }
    }

    let values = compact ? compactSamples : samples
    let curve = NSBezierPath()
    for (index, value) in values.enumerated() {
        let point = NSPoint(x: graph.minX + graph.width * CGFloat(index) / CGFloat(values.count - 1),
                            y: graph.minY + graph.height * value)
        index == 0 ? curve.move(to: point) : curve.line(to: point)
    }
    let area = curve.copy() as! NSBezierPath
    area.line(to: NSPoint(x: graph.maxX, y: graph.minY))
    area.line(to: NSPoint(x: graph.minX, y: graph.minY))
    area.close()
    NSGraphicsContext.saveGraphicsState()
    area.addClip()
    loadGradient.draw(in: graph, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    curve.lineWidth = compact ? 34 : 18
    curve.lineJoinStyle = .round
    curve.lineCapStyle = .round
    rgb(255, 255, 255, 0.85).setStroke()
    curve.stroke()

    // Jauges.
    let meters: [(CGFloat, NSColor)] = compact
        ? [(0.7, rgb(10, 132, 255))]
        : [(0.72, rgb(10, 132, 255)), (0.45, rgb(191, 90, 242)), (0.88, rgb(255, 69, 58))]
    let meterHeight: CGFloat = compact ? 90 : 44
    var y: CGFloat = compact ? 200 : 300
    for (fraction, color) in meters {
        let track = NSRect(x: graph.minX, y: y, width: graph.width, height: meterHeight)
        rgb(255, 255, 255, 0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: meterHeight / 2, yRadius: meterHeight / 2).fill()
        color.setFill()
        var filled = track
        filled.size.width *= fraction
        NSBezierPath(roundedRect: filled, xRadius: meterHeight / 2, yRadius: meterHeight / 2).fill()
        y -= meterHeight + 26
    }
}

let iconset = URL(fileURLWithPath: outputDirectory).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = base * factor
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
print("OK : \(iconset.path)")
