# LidMute

LidMute 是一个面向 macOS 的菜单栏守卫应用，用来在合盖、夜间静音和特定音频场景下保护内建扬声器，避免意外外放。应用提供主界面、状态栏入口、本地事件时间线，以及可选的 Chrome 扩展桥接能力。

界面修改必须遵守 [中文设计说明中的强制视觉设计原则](docs/LidMute-中文设计说明.md#三视觉设计原则强制)。

## 项目功能

- 合盖守卫：检测 Mac 合盖状态，在守卫开启时保护内建扬声器。
- 状态栏控制：可从菜单栏快速开启或关闭守卫。
- 轻量模式：可隐藏主窗口和 Dock 图标，仅保留状态栏入口。
- 夜间静音：支持北京时间时段配置，结合屏幕休眠状态自动保护扬声器。
- 模拟合盖 / 开盖：可在主界面内模拟状态变化，便于调试状态机。
- 媒体控制：支持系统级上一首、下一首、播放 / 暂停。
- Chrome 标签页音频桥接：可记录 Chrome 标签页标题、URL、窗口 ID、标签 ID 和 `audible` 变化，辅助定位音频来源。
- 本地事件时间线：所有关键动作会记录到本地，方便回溯和排查。

## 构建与验证

```zsh
cd /Users/han/temp/workspace/LidMute
chmod +x Scripts/*.sh
Scripts/run-smoke-check.sh
```

这台机器的 Command Line Tools 不提供 XCTest 或 Swift Testing，因此仓库使用无依赖的可执行行为测试套件代替 `swift test`。该检查能验证编译、核心假适配器行为以及扩展帧解析，但不能覆盖真实合盖事件、真实 CoreAudio 控制和已加载的 Chrome 扩展。

## 运行

```zsh
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache \
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteApp
```

如果要生成并运行本地 `.app`：

```zsh
zsh Scripts/make-app-bundle.sh
open dist/LidMute.app
```

`make-app-bundle.sh` 会在打包前执行视觉原则检查，并强制基于当前源码重新构建，避免把旧二进制复制进 `dist/LidMute.app`。

## Chrome 标签页日志能力

1. 打开 `chrome://extensions`。
2. 开启开发者模式并加载仓库内的 `ChromeExtension` 目录。
3. 复制生成的扩展 ID。
4. 运行注册脚本，把扩展 ID 写入 native host 配置。

```zsh
Scripts/register-chrome-host.sh /tmp/lidmute-build/arm64-apple-macosx/debug/LidMuteNativeHost EXTENSION_ID
```

注册成功后，LidMute 在活动日志里可以记录 Chrome 标签页的标题、URL、窗口 ID、标签 ID 和音频状态变化。

## 手动验证建议

1. 启动 LidMute，开启守卫，确认关闭主窗口后状态栏开关仍可用。
2. 在未接有线耳机时，使用“模拟合盖”确认时间线出现静音保护事件。
3. 启用轻量模式，确认主窗口和 Dock 图标隐藏，但状态栏入口仍保留。
4. 关闭轻量模式，确认主窗口恢复。
5. 加载 Chrome 扩展并注册扩展 ID，播放媒体后确认日志出现对应标签页信息。

## 已知限制

- LidMute 保护的是声音输出，不会主动暂停视频或结束进程。
- macOS 原生只提供进程级音频活动，Chrome 的标签页级归因依赖扩展和 native host。
- 某些硬件上的内建音频设备可能和模拟耳机共享路由。LidMute 在无法明确识别为内建扬声器时会拒绝修改该路由，以避免误操作。

## 补充说明

- [README.zh-CN](README.zh-CN.md) 提供简版中文说明。
- `dist/` 和 `.build/` 都不纳入版本控制。
