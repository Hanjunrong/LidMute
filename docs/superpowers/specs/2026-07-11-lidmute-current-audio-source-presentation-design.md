# LidMute 当前声音来源展示设计

## 目标

“当前声音”卡片不再以 PID 作为主要识别信息。Chrome 优先展示正在发声的标签页标题，其他进程展示 macOS 应用名称；活动时间线复用相同的标题和副标题规则。

## 展示规则

- Chrome 有当前标签页证据时：主标题为标签页标题，副标题为 `Google Chrome · URL`，图标使用网页图标。
- 普通音频进程：主标题为应用名称，副标题优先使用 Bundle ID，其次使用可执行路径，图标使用应用图标。
- PID 仅在应用名称、Bundle ID 和路径都不可用时显示，不再作为行尾固定字段。
- 多个普通音频进程分别显示。Chrome 在现有协议能力内显示最近一次收到的发声标签页证据。

## 当前状态与生命周期

Chrome 扩展当前只发送 `tab_audio_started`，没有停止事件。AppViewModel 保存最近收到的 Chrome 标签页证据，但只有 CoreAudio 仍报告 Chrome 进程正在输出时才将它作为当前声音来源。Chrome 进程停止输出后立即清除该证据，避免把永久日志中的历史标签页误显示为当前声音。

后续如果扩展增加停止事件，可把单一最近证据升级为按 `windowID + tabID` 管理的活动标签页集合；本次不扩大协议。

## 组件边界

- LidMuteCore 新增纯数据的声音来源展示模型和统一格式化规则，可被卡片及日志共同复用。
- AppViewModel 将 CoreAudio 进程和最新 Chrome 证据合成为当前声音来源列表。
- ContentView 只渲染展示模型，不自行判断 PID、Bundle ID 或标签页优先级。
- EventTimelineRow 使用同一格式化规则展示事件附带的进程或标签页信息。

## 验证

- 单元测试覆盖 Chrome 标签页优先、普通 App 名称优先和 PID 兜底。
- 行为测试覆盖 Chrome 输出停止后不再显示历史标签页。
- 完整构建并重新生成 `dist/LidMute.app`；实际 UI 验收由用户完成。
