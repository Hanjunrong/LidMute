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
    fputs("Unable to create image representation\\n", stderr)
    exit(1)
}

guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("Unable to create graphics context\\n", stderr)
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

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high
graphics.cgContext.setAllowsAntialiasing(true)
graphics.cgContext.setShouldAntialias(true)
graphics.cgContext.clear(canvas)

// A restrained, macOS-native base lets the mark remain recognisable at Dock size.
let baseRect = NSRect(x: 48, y: 48, width: 928, height: 928)
let base = NSBezierPath(roundedRect: baseRect, xRadius: 214, yRadius: 214)
let shadow = NSShadow()
shadow.shadowBlurRadius = 32
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowColor = color(29, 34, 38, 0.20)
shadow.set()
gradient(base, [color(255, 253, 248), color(232, 239, 237)], angle: 45)

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics

let inset = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 184, yRadius: 184)
stroke(inset, color(255, 255, 255, 0.78), width: 5)

// The main object is a shut clamshell: two shallow planes, not an upright display.
let lid = NSBezierPath()
lid.move(to: NSPoint(x: 211, y: 561))
lid.line(to: NSPoint(x: 778, y: 561))
lid.curve(to: NSPoint(x: 812, y: 530), controlPoint1: NSPoint(x: 796, y: 561), controlPoint2: NSPoint(x: 812, y: 548))
lid.line(to: NSPoint(x: 755, y: 394))
lid.curve(to: NSPoint(x: 725, y: 375), controlPoint1: NSPoint(x: 749, y: 382), controlPoint2: NSPoint(x: 739, y: 375))
lid.line(to: NSPoint(x: 264, y: 375))
lid.curve(to: NSPoint(x: 238, y: 394), controlPoint1: NSPoint(x: 250, y: 375), controlPoint2: NSPoint(x: 242, y: 382))
lid.line(to: NSPoint(x: 178, y: 530))
lid.curve(to: NSPoint(x: 211, y: 561), controlPoint1: NSPoint(x: 178, y: 548), controlPoint2: NSPoint(x: 194, y: 561))
lid.close()
gradient(lid, [color(18, 28, 32), color(39, 66, 67)], angle: 52)

let lidReflection = NSBezierPath()
lidReflection.move(to: NSPoint(x: 264, y: 552))
lidReflection.line(to: NSPoint(x: 725, y: 552))
stroke(lidReflection, color(171, 237, 224, 0.36), width: 6)

let base = NSBezierPath(roundedRect: NSRect(x: 164, y: 324, width: 664, height: 72), xRadius: 36, yRadius: 36)
gradient(base, [color(32, 45, 49), color(83, 108, 108)], angle: 0)
let hingeLip = NSBezierPath(roundedRect: NSRect(x: 443, y: 347, width: 138, height: 16), xRadius: 8, yRadius: 8)
color(218, 242, 235, 0.50).setFill()
hingeLip.fill()

// A quiet Apple reference on the closed lid; it stays secondary to the mute state.
symbol("apple.logo", in: NSRect(x: 470, y: 442, width: 78, height: 78), tint: color(237, 246, 241, 0.88))

let badge = NSBezierPath(ovalIn: NSRect(x: 606, y: 493, width: 182, height: 182))
gradient(badge, [color(255, 190, 89), color(238, 96, 39)], angle: 45)

let speaker = NSBezierPath()
speaker.move(to: NSPoint(x: 642, y: 591))
speaker.line(to: NSPoint(x: 671, y: 591))
speaker.line(to: NSPoint(x: 708, y: 626))
speaker.line(to: NSPoint(x: 708, y: 544))
speaker.line(to: NSPoint(x: 671, y: 578))
speaker.line(to: NSPoint(x: 642, y: 578))
speaker.close()
color(255, 250, 244).setFill()
speaker.fill()

let slash = NSBezierPath()
slash.move(to: NSPoint(x: 682, y: 543))
slash.line(to: NSPoint(x: 750, y: 623))
stroke(slash, color(41, 55, 55), width: 17)

let soundArc = NSBezierPath()
soundArc.appendArc(withCenter: NSPoint(x: 707, y: 584), radius: 48, startAngle: -35, endAngle: 35, clockwise: false)
stroke(soundArc, color(255, 250, 244, 0.76), width: 9)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode PNG\\n", stderr)
    exit(1)
}

do {
    try png.write(to: outputURL, options: .atomic)
    print("Wrote \(outputURL.path)")
} catch {
    fputs("Unable to write PNG: \(error.localizedDescription)\n", stderr)
    exit(1)
}
