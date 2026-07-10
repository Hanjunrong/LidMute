# LidMute 琥珀控制台 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current stacked dark dashboard with the approved Amber Control Deck, including a wide status hero, two-column functional cards, readable event timeline, and Liquid Glass-adapted controls.

**Architecture:** Preserve `AppViewModel` and all audio behavior. Move reusable color, glass surface, button, and event-presentation concerns into focused Swift files, then rebuild `ContentView` as a responsive composition that consumes the existing published state.

**Tech Stack:** Swift 6, SwiftUI, macOS 15 minimum, macOS 26 `glassEffect` with material fallback, AppKit accessibility verification, executable Swift behavior tests.

## Global Constraints

- Do not change guard, lid, night schedule, Chrome bridge, media command, persistence, or audio-routing behavior.
- Default window is approximately `980 x 760`; minimum size is `900 x 700`.
- macOS 26 buttons use interactive Liquid Glass; earlier systems use material fallback.
- No system-blue solid buttons, flat black dashboard, or opaque nested cards.
- Every existing action remains reachable and identifiable through the accessibility tree.

---

### Task 1: Event Presentation Model

**Files:**
- Create: `Sources/LidMuteCore/EventPresentation.swift`
- Modify: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Consumes: `LidMuteEventKind`
- Produces: `EventPresentation(kind:)` with `title: String` and `symbolName: String`

- [ ] **Step 1: Write the failing presentation test**

```swift
private static func eventPresentationUsesReadableChineseLabels() throws {
    let detected = EventPresentation(kind: .audioProcessDetected)
    let restored = EventPresentation(kind: .restored)
    guard detected.title == "检测到音频输出",
          detected.symbolName == "waveform.badge.exclamationmark",
          restored.title == "扬声器状态已恢复" else {
        throw BehaviorTestError.expectationFailed("event presentation is not human readable")
    }
}
```

- [ ] **Step 2: Run the behavior executable and verify RED**

Run: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache swift run --disable-sandbox --scratch-path /tmp/lidmute-ui-red LidMuteCoreBehaviorTests`

Expected: compile failure because `EventPresentation` does not exist.

- [ ] **Step 3: Implement the value type and complete mappings**

```swift
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
```

- [ ] **Step 4: Run tests and verify GREEN**

Run the command from Step 2.

Expected: all existing and new behavior checks pass.

### Task 2: Visual Theme and Liquid Glass Controls

**Files:**
- Create: `Sources/LidMuteApp/AmberVisualTheme.swift`
- Create: `Sources/LidMuteApp/LiquidGlassControls.swift`
- Modify: `Sources/LidMuteApp/ContentView.swift`

**Interfaces:**
- Produces: `AmberVisualTheme`, `AmberGlassCard`, `LiquidGlassButtonStyle`, `LiquidGlassIconButtonStyle`
- Button style arguments: `tint: Color`, `isEmphasized: Bool`, `shape: LiquidGlassButtonShape`

- [ ] **Step 1: Add a compile-time usage site before the styles exist**

```swift
Button("开启守卫") { model.setEnabled(true) }
    .buttonStyle(LiquidGlassButtonStyle(tint: AmberVisualTheme.amber, isEmphasized: true, shape: .capsule))
```

- [ ] **Step 2: Run `swift build` and verify RED**

Run: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache swift build --disable-sandbox --scratch-path /tmp/lidmute-ui-build`

Expected: compile failure because the new theme and style types do not exist.

- [ ] **Step 3: Implement the styles with macOS 26 and fallback branches**

```swift
@ViewBuilder
private func styledBody(configuration: Configuration) -> some View {
    if #available(macOS 26.0, *) {
        configuration.label
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(tint.opacity(isEmphasized ? 0.34 : 0.12)).interactive(), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    } else {
        configuration.label
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.42)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
```

- [ ] **Step 4: Build and verify GREEN**

Run the command from Step 2.

Expected: `LidMuteApp` compiles with no new warnings or errors.

### Task 3: Amber Control Deck Layout

**Files:**
- Modify: `Sources/LidMuteApp/ContentView.swift`
- Modify: `Sources/LidMuteApp/LidMuteApp.swift`

**Interfaces:**
- Consumes existing `AppViewModel` published properties and actions without signature changes.
- Produces `HeaderBar`, `GuardHero`, `AutomationCard`, `NowPlayingCard`, `ActivityTimeline`, and reusable `MetricLabel` private views.

- [ ] **Step 1: Replace the vertical stack with the approved hierarchy**

```swift
VStack(spacing: 16) {
    HeaderBar(model: model)
    GuardHero(model: model)
    HStack(alignment: .top, spacing: 16) {
        AutomationCard(model: model).frame(maxWidth: .infinity)
        NowPlayingCard(model: model).frame(maxWidth: .infinity)
    }
    ActivityTimeline(events: model.events).frame(maxHeight: .infinity)
}
```

- [ ] **Step 2: Apply the warm atmosphere and responsive window geometry**

```swift
.background(AmberVisualTheme.atmosphere.ignoresSafeArea())
.frame(minWidth: 900, minHeight: 700)
```

Set the initial window size to approximately `980 x 760` using `defaultSize(width:height:)` where available.

- [ ] **Step 3: Convert all actions to glass controls**

Use `LiquidGlassButtonStyle` for guard, schedule, simulation, reset, and clear actions. Use `LiquidGlassIconButtonStyle` for previous, play/pause, and next. Preserve `.disabled(...)` and accessibility labels.

- [ ] **Step 4: Build and run the complete smoke check**

Run: `zsh Scripts/run-smoke-check.sh`

Expected: Swift behavior tests, Chrome tests, app build, and two bundle builds all pass.

### Task 4: Visual and Accessibility Verification

**Files:**
- Modify: `README.md` only if window instructions need updating.

**Interfaces:**
- Verifies the packaged app at `dist/LidMute.app`.

- [ ] **Step 1: Launch a fresh packaged process**

Run: `killall LidMute` followed by `open /Users/han/temp/workspace/LidMute/dist/LidMute.app` with the required approvals.

- [ ] **Step 2: Inspect the screenshot and accessibility tree**

Confirm the Hero, two functional cards, activity timeline, guard switch, schedule apply, simulation/reset/clear, Chrome status, and three media controls are visible.

- [ ] **Step 3: Verify interaction states without mutating real audio**

Check hover/disabled rendering and the reset simulation button state. Do not click guard or media controls during visual QA.

- [ ] **Step 4: Run final repository audit and commit**

Run: `git diff --check`, `plutil -lint dist/LidMute.app/Contents/Info.plist`, and `git status --short`.

Commit: `feat: redesign LidMute amber control deck`
