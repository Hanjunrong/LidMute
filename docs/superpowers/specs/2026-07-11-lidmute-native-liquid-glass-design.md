# LidMute 原生 Liquid Glass 设计

## 目标

让生成的 LidMute macOS app 在 macOS 26 上使用 SwiftUI 原生 Liquid Glass：背景、主要卡片、状态胶囊、输入框和操作按钮都应有可辨识的玻璃表面，同时继续兼容 macOS 15 的材质回退。

## 设计

- 保持 `Package.swift` 的 macOS 15 最低部署目标，使用 `#available(macOS 26.0, *)` 选择原生路径。
- 根内容使用 `GlassEffectContainer` 组织卡片和控件，并在光场背景上增加一层低对比度的原生玻璃面板。
- `amberGlassCard` 在 macOS 26 使用 `.glassEffect(.regular.tint(...), in: ...)`；旧系统继续使用 `.ultraThinMaterial` 和高光描边。
- 所有 `LiquidGlassButtonStyle` 和 `LiquidGlassIconButtonStyle` 在 macOS 26 使用带 `.interactive()` 的原生玻璃；按压、禁用和强调状态仅通过 tint、透明度和缩放表达。
- 状态胶囊、指标胶囊和时间输入框使用同一套玻璃表面语言，避免页面只有按钮像玻璃而背景仍是透明色块。
- 不改变 `AppViewModel`、音频控制、Chrome bridge 或用户操作语义。

## 验证

- 使用当前 macOS 26 SDK 构建 `LidMuteApp`。
- 运行现有 smoke check 和核心行为测试。
- 重新生成 `dist/LidMute.app`，检查 app 二进制和 `Info.plist` 存在，并确认工作区原有未提交业务改动未被覆盖。
