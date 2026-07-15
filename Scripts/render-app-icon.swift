#!/usr/bin/env swift

import AppKit

let outputPath = CommandLine.arguments.last(where: { $0.hasSuffix(".png") }) ?? "Assets/AppIcon-1024.png"
let outputURL = URL(fileURLWithPath: outputPath)
let side: CGFloat = 1024
let canvas = NSRect(x: 0, y: 0, width: side, height: side)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side),
    pixelsHigh: Int(side),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Unable to create image representation\n", stderr)
    exit(1)
}

guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("Unable to create graphics context\n", stderr)
    exit(1)
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ path: NSBezierPath, _ colors: [NSColor], angle: CGFloat) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}

func stroke(_ path: NSBezierPath, _ tint: NSColor, width: CGFloat) {
    tint.setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

func symbol(_ name: String, in rect: NSRect, tint: NSColor, weight: NSFont.Weight = .medium) {
    let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let tinted = image.copy() as! NSImage
    tinted.lockFocus()
    tint.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: rect)
}

func drawGlow(in rect: NSRect, tint: NSColor, blur: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = .zero
    shadow.shadowColor = tint
    shadow.set()
    tint.withAlphaComponent(0.72).setFill()
    NSBezierPath(ovalIn: rect).fill()
    NSGraphicsContext.restoreGraphicsState()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high
graphics.cgContext.setAllowsAntialiasing(true)
graphics.cgContext.setShouldAntialias(true)
graphics.cgContext.clear(canvas)

// A future-facing Aurora Glass superellipse: warm protection light flows into
// cool connected-state color while keeping enough contrast at Dock size.
let baseRect = NSRect(x: 48, y: 48, width: 928, height: 928)
let base = NSBezierPath(roundedRect: baseRect, xRadius: 220, yRadius: 220)
let baseShadow = NSShadow()
baseShadow.shadowBlurRadius = 44
baseShadow.shadowOffset = NSSize(width: 0, height: -16)
baseShadow.shadowColor = color(26, 44, 52, 0.28)
baseShadow.set()
gradient(
    base,
    [color(255, 190, 121), color(136, 211, 207), color(119, 163, 232)],
    angle: 38
)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

// Refracted color fields sit underneath the glass plate.
base.addClip()
drawGlow(in: NSRect(x: -90, y: 550, width: 560, height: 560), tint: color(255, 132, 48, 0.54), blur: 92)
drawGlow(in: NSRect(x: 560, y: -40, width: 560, height: 560), tint: color(42, 205, 191, 0.50), blur: 96)
drawGlow(in: NSRect(x: 500, y: 570, width: 460, height: 380), tint: color(128, 146, 255, 0.36), blur: 88)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

// Outer optical rim catches light at the upper-left and fades toward the edge.
let outerRim = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
stroke(outerRim, color(255, 255, 255, 0.76), width: 7)

let plateRect = NSRect(x: 126, y: 126, width: 772, height: 772)
let plate = NSBezierPath(roundedRect: plateRect, xRadius: 172, yRadius: 172)
gradient(
    plate,
    [color(255, 255, 255, 0.54), color(235, 250, 250, 0.28), color(244, 247, 255, 0.18)],
    angle: 48
)
stroke(plate, color(255, 255, 255, 0.76), width: 6)

// A second inset line suggests a layered glass edge rather than a flat tile.
let innerRim = NSBezierPath(roundedRect: NSRect(x: 145, y: 145, width: 734, height: 734), xRadius: 154, yRadius: 154)
stroke(innerRim, color(255, 255, 255, 0.28), width: 3)

// The large shield is the primary semantic silhouette and remains legible at 32px.
symbol(
    "shield.fill",
    in: NSRect(x: 278, y: 258, width: 468, height: 500),
    tint: color(245, 252, 251, 0.88),
    weight: .semibold
)

// A glass mute badge gives LidMute its product-specific meaning.
let badgeRect = NSRect(x: 548, y: 236, width: 270, height: 270)
let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 92, yRadius: 92)
let badgeShadow = NSShadow()
badgeShadow.shadowBlurRadius = 34
badgeShadow.shadowOffset = NSSize(width: 0, height: -10)
badgeShadow.shadowColor = color(71, 54, 45, 0.26)
badgeShadow.set()
gradient(badge, [color(255, 178, 79, 0.96), color(242, 101, 54, 0.94)], angle: 45)

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

stroke(badge, color(255, 255, 255, 0.72), width: 5)
symbol(
    "speaker.slash.fill",
    in: NSRect(x: 600, y: 288, width: 166, height: 166),
    tint: color(255, 255, 255, 0.96),
    weight: .semibold
)

// Restrained specular highlights establish the shared upper-left light source.
let topHighlight = NSBezierPath()
topHighlight.move(to: NSPoint(x: 206, y: 812))
topHighlight.curve(
    to: NSPoint(x: 676, y: 862),
    controlPoint1: NSPoint(x: 340, y: 904),
    controlPoint2: NSPoint(x: 548, y: 904)
)
stroke(topHighlight, color(255, 255, 255, 0.50), width: 12)

let badgeHighlight = NSBezierPath()
badgeHighlight.move(to: NSPoint(x: 594, y: 438))
badgeHighlight.curve(
    to: NSPoint(x: 738, y: 468),
    controlPoint1: NSPoint(x: 632, y: 482),
    controlPoint2: NSPoint(x: 698, y: 492)
)
stroke(badgeHighlight, color(255, 255, 255, 0.42), width: 8)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: outputURL, options: .atomic)
    print("Wrote \(outputURL.path)")
} catch {
    fputs("Unable to write PNG: \(error.localizedDescription)\n", stderr)
    exit(1)
}
