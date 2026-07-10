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
        for keyState in [0xA, 0xB] {
            let data1 = (command.rawValue << 16) | (keyState << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent else {
                throw SystemMediaError.eventCreationFailed
            }
            event.post(tap: .cghidEventTap)
        }
    }
}
