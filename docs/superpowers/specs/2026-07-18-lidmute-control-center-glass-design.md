# LidMute Control Center Glass 全面视觉适配设计

## 目标

将 LidMute 主窗口升级为用户选定的 B「Control Center Glass」方向，全面统一卡片、按钮、字体、状态色和交互反馈，同时保持现有业务行为与零间距布局契约不变。

## 视觉层级

- Hero 是最厚、最亮的玻璃层，承载守卫状态、核心说明和主操作。
- 当前声音使用次厚玻璃，突出实时媒体状态和圆形媒体控制器。
- 自动保护与模拟测试使用中等玻璃，强调可操作性但不与 Hero 竞争。
- 时间线使用最安静、最接近实体的表面，优先保证长文本和时间戳可读。
- 背景使用低饱和琥珀、海玻璃和雾蓝环境光；深色模式降低亮度并加强空间纵深。

## 卡片与布局

- 保持 `VisualLayoutMetrics.cardSpacing = 0`、固定卡片高度和仅时间线随窗口增长的规则。
- 保持每张卡片独立四角圆角；使用边缘高光、内描边和不同材质厚度建立层级，不引入真实卡片间距。
- 保持内容先撑满 frame、再 padding、最后应用卡片背景的 modifier 顺序。
- 不修改 Chrome、音频、合盖监控、夜间策略和事件存储的数据流。

## 控件与反馈

- 主按钮使用琥珀色强调玻璃，非主按钮使用海玻璃或雾蓝色玻璃。
- 媒体控制继续采用圆形按钮，并通过更强的中心主按钮体现层级。
- 按下反馈立即发生：文字按钮缩放到 `0.97`，图标按钮缩放到 `0.94`。
- 回弹使用临界阻尼 `spring(response: 0.30, dampingFraction: 1.0)`，不使用固定时长 `easeOut`。
- macOS 26 使用原生 `.glassEffect(...interactive())`；macOS 15–25 使用渐变、描边和阴影回退。

## 字体系统

- 全部使用 SwiftUI 系统字体，不引入自定义字体。
- 品牌标题使用 24pt semibold，避免 rounded heavy。
- Hero 标题使用 30pt bold、紧字距和紧行距。
- 卡片标题使用 15pt semibold；正文使用 13pt regular；辅助说明使用 12pt medium。
- 时间、计数和持续时间使用 monospaced digits。
- 字重与字号共同表达层级，避免通过高饱和颜色替代排版层级。

## 无障碍

- `accessibilityReduceMotion` 开启时，移除缩放与 spring，仅保留短淡变或即时状态变化。
- `accessibilityReduceTransparency` 开启时，提高表面不透明度并停用原生玻璃效果的透明表现。
- `accessibilityDifferentiateWithoutColor` 开启时，状态继续通过图标、文字和轮廓表达，不只依赖颜色。
- 维持现有按钮、开关和状态的 accessibility label/value。

## 文件边界

- `Sources/LidMuteApp/AmberVisualTheme.swift`：色板、材质厚度、字体 token、卡片表面和图标底座。
- `Sources/LidMuteApp/LiquidGlassControls.swift`：按钮即时反馈、spring、减少动态效果和控件光学层级。
- `Sources/LidMuteApp/ContentView.swift`：应用统一字体 token、状态胶囊和卡片角色，不改业务逻辑。
- `Scripts/check-visual-principles.sh`：新增 Control Center Glass 的字体、spring 和无障碍静态契约。

## 验证边界

- 自动验证：视觉原则脚本、核心行为测试、打包脚本和 codesign。
- 不执行视觉验收；最终浅色/深色、窗口缩放和实际观感由用户测试。
- 最终产物必须由 `zsh Scripts/make-app-bundle.sh` 生成，禁止以 `.build` 中的二进制作为验收对象。

## 非目标

- 不修改应用图标。
- 不增加页面、导航或新的业务功能。
- 不改变窗口尺寸契约和时间线行数规则。
- 不引入第三方依赖或持续循环动画。
