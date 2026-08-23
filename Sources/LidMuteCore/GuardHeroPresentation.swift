public struct GuardHeroPresentation: Equatable, Sendable {
    public let eyebrow: String
    public let title: String
    public let subtitle: String
    public let canToggleGuard: Bool

    public init(
        lifecycleState: AppLifecycleState,
        isEnabled: Bool,
        isNightProtectionActive: Bool,
        statusText: String
    ) {
        canToggleGuard = lifecycleState == .ready
        switch lifecycleState {
        case .recovering:
            eyebrow = "正在恢复"
            title = "正在确认扬声器安全状态"
            subtitle = statusText
        case .shutdownUnresolved:
            eyebrow = "恢复未完成"
            title = "正在确认关机恢复结果"
            subtitle = statusText
        case .recoveryBlocked:
            eyebrow = "需要处理"
            title = "守卫暂不可用"
            subtitle = statusText
        case .ready:
            eyebrow = isEnabled ? "守卫已开启" : "守卫未开启"
            if !isEnabled {
                title = "安静由你决定"
                subtitle = "开启后，只有合盖或夜间息屏策略会触发静音。"
            } else if isNightProtectionActive {
                title = "夜间模式正在保护外放"
                subtitle = "只控制 Mac 内建扬声器，耳机与外接音频不会被修改。"
            } else if statusText.contains("正在保护") {
                title = "外放安静，一切正常"
                subtitle = "只控制 Mac 内建扬声器，耳机与外接音频不会被修改。"
            } else {
                title = "等待合盖或夜间息屏"
                subtitle = "只控制 Mac 内建扬声器，耳机与外接音频不会被修改。"
            }
        }
    }
}
