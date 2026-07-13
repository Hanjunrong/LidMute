import AppKit
import CoreGraphics
import Foundation
import LidMuteCore

enum SystemMediaError: LocalizedError {
    case eventCreationFailed

    var errorDescription: String? {
        "无法创建 macOS 系统媒体按键事件"
    }
}

final class SystemMediaController {
    func send(_ command: MediaCommand) throws {
        for descriptor in MediaKeyEventDescriptor.events(for: command) {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: descriptor.modifierFlags),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: descriptor.data1,
                data2: -1
            )?.cgEvent else {
                throw SystemMediaError.eventCreationFailed
            }
            event.post(tap: .cghidEventTap)
        }
    }
}
