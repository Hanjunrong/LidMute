import Foundation

public struct NightSchedule: Codable, Equatable, Sendable {
    public let startMinutes: Int
    public let endMinutes: Int
    public let timeZoneIdentifier: String

    public init(
        startMinutes: Int = 0,
        endMinutes: Int = 8 * 60,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) {
        self.startMinutes = min(max(startMinutes, 0), 23 * 60 + 59)
        self.endMinutes = min(max(endMinutes, 0), 23 * 60 + 59)
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public func isActive(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let currentMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinutes == endMinutes { return false }
        if startMinutes < endMinutes {
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        }
        return currentMinutes >= startMinutes || currentMinutes < endMinutes
    }

    public static let defaultBeijing = NightSchedule()
}
