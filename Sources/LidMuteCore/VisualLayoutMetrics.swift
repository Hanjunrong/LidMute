import Foundation

public enum VisualLayoutMetrics {
    public static let cardSpacing: Double = 0
    public static let appPadding: Double = 6
    public static let timelineVisibleRowCount = 3
    public static let timelineRowHeight: Double = 72
    public static let timelineHeaderAndPaddingHeight: Double = 60
    public static let timelineMinimumCardHeight: Double =
        timelineHeaderAndPaddingHeight + timelineDefaultViewportHeight
    public static let headerHeight: Double = 54
    public static let guardCardHeight: Double = 148
    public static let middleDeckHeight: Double = 190
    public static let automationCardHeight: Double = 128
    public static let simulationCardHeight: Double = middleDeckHeight - automationCardHeight
    public static let fixedContentHeightBeforeTimeline: Double =
        headerHeight + guardCardHeight + middleDeckHeight
    public static let defaultWindowHeight: Double = 680

    public static var timelineDefaultViewportHeight: Double {
        timelineRowHeight * Double(timelineVisibleRowCount)
    }

    public static func timelineViewportHeight(forAvailableContentHeight availableHeight: Double) -> Double {
        let availableTimelineHeight = availableHeight - fixedContentHeightBeforeTimeline
        return max(timelineDefaultViewportHeight, availableTimelineHeight - timelineHeaderAndPaddingHeight)
    }
}
