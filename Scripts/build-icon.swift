#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: build-icon.swift ICONSET OUTPUT.icns\n", stderr)
    exit(64)
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let entries = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

do {
    var body = Data()
    for (type, filename) in entries {
        let image = try Data(contentsOf: iconset.appending(path: filename))
        body.append(Data(type.utf8))
        appendBigEndian(UInt32(image.count + 8), to: &body)
        body.append(image)
    }

    var container = Data("icns".utf8)
    appendBigEndian(UInt32(body.count + 8), to: &container)
    container.append(body)
    try container.write(to: output, options: .atomic)
} catch {
    fputs("Unable to build app icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
