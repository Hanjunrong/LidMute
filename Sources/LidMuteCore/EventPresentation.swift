public struct EventPresentation: Equatable, Sendable {
    public let title: String
    public let symbolName: String

    public init(kind: LidMuteEventKind) {
        switch kind {
        case .protectionEnabled:
            (title, symbolName) = ("守卫已开启", "shield.fill")
        case .protectionDisabled:
            (title, symbolName) = ("守卫已关闭", "shield.slash")
        case .lidClosed:
            (title, symbolName) = ("检测到合盖", "laptopcomputer")
        case .lidOpened:
            (title, symbolName) = ("检测到开盖", "laptopcomputer.and.arrow.up")
        case .muteEnforced:
            (title, symbolName) = ("已保持静音", "speaker.slash.fill")
        case .restored:
            (title, symbolName) = ("扬声器状态已恢复", "speaker.wave.2.fill")
        case .audioProcessDetected:
            (title, symbolName) = ("检测到音频输出", "waveform.badge.exclamationmark")
        case .chromeTabAudible:
            (title, symbolName) = ("Chrome 标签页发声", "globe")
        case .error:
            (title, symbolName) = ("发生错误", "exclamationmark.triangle.fill")
        case .simulation:
            (title, symbolName) = ("模拟状态变化", "testtube.2")
        case .nightProtectionStarted:
            (title, symbolName) = ("夜间保护已开始", "moon.stars.fill")
        case .nightProtectionEnded:
            (title, symbolName) = ("夜间保护已结束", "sunrise.fill")
        case .mediaCommandSent:
            (title, symbolName) = ("媒体命令已发送", "playpause.fill")
        }
    }
}
