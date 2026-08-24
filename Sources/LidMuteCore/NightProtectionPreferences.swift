import Foundation

public struct NightProtectionConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let startText: String
    public let endText: String

    public init(enabled: Bool, startText: String, endText: String) {
        self.enabled = enabled
        self.startText = startText
        self.endText = endText
    }
}

public final class NightProtectionPreferences: @unchecked Sendable {
    private enum Key {
        static let enabled = "nightScheduleEnabled"
        static let start = "nightStart"
        static let end = "nightEnd"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> NightProtectionConfiguration {
        let enabled = defaults.bool(forKey: Key.enabled)
        let startText = defaults.string(forKey: Key.start) ?? "00:00"
        let endText = defaults.string(forKey: Key.end) ?? "08:00"
        guard let startMinutes = Self.minutes(from: startText),
              let endMinutes = Self.minutes(from: endText),
              NightSchedule.isValid(startMinutes: startMinutes, endMinutes: endMinutes) else {
            return NightProtectionConfiguration(enabled: enabled, startText: "00:00", endText: "08:00")
        }
        return NightProtectionConfiguration(
            enabled: enabled,
            startText: startText,
            endText: endText
        )
    }

    public func saveEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.enabled)
    }

    @discardableResult
    public func saveSchedule(startText: String, endText: String) -> Bool {
        guard let startMinutes = Self.minutes(from: startText),
              let endMinutes = Self.minutes(from: endText),
              NightSchedule.isValid(startMinutes: startMinutes, endMinutes: endMinutes) else { return false }
        defaults.set(startText, forKey: Key.start)
        defaults.set(endText, forKey: Key.end)
        return true
    }

    public static func minutes(from text: String) -> Int? {
        let characters = Array(text)
        guard characters.count == 5, characters[2] == ":",
              let hour = Int(String(characters[0...1])),
              let minute = Int(String(characters[3...4])),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
