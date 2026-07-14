# LidMute project conventions for AI agents

## Build

Must use the **project's packaging script**, never `swift build` directly:

```sh
zsh Scripts/make-app-bundle.sh
```

This script:
- Uses an independent `--scratch-path` (default: `/tmp/lidmute-build`)
- Runs visual principle checks before building
- Rejects stale binaries (sources newer than binary → exit 67)
- Packages the result into `dist/LidMute.app` (Info.plist, icons, native host, Chrome extension)
- Direct `swift build` only updates `.build/` — the end-user runs `dist/LidMute.app`.

## Visual principles

- **Zero card spacing**: `VisualLayoutMetrics.cardSpacing = 0` — card frames are exactly adjacent
- **Per-card rounded corners**: Each card has its own `amberGlassCard(padding: 0, cornerRadius: 14)` — all 4 corners rounded, individual glass background + stroke overlay
## Card layout principle

**Content must fill frame before padding + background are applied.**

Cards follow this modifier order:

```
ContentStack(...)
    .frame(maxHeight: .infinity)    // ① 撑满：扩展到外层 frame 提供的空间
    .padding(10)                     // ② 再加内边距
    .amberGlassCard(...)             // ③ 背景/描边覆盖整个 frame
```

Why: intrinsic content height < `.frame(height: X)` → SwiftUI 居中内容 → background 只覆盖内容区域，不撑到 frame 边界 → 卡片间出现透明间隙。

Example: GuardHero content ≈ 106pt → `.padding(10)` = 126pt → `.frame(height: 148)` → 内容居中 → 上下各 11pt 空隙。

Fix: `.frame(maxHeight: .infinity)` 让内容先扩展到 frame 可用空间，padding 和 background 随后覆盖整个区域。

This applies to all cards (GuardHero, AutomationCard, SimulationCard, NowPlayingCard) except ActivityTimeline, which has dynamic height and no fixed `.frame(height:)`.

## Debug layout

When cards have unexpected gaps, check frame boundaries vs card backgrounds:

```swift
// Replace amberGlassCard with colored bg + border to see the frame:
// .amberGlassCard(padding: 0, cornerRadius: 14)
.background(Color.red, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
.overlay(
    RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(.white.opacity(0.45), lineWidth: 1.2)
)
```

Then add `.border()` on container views to see their frame bounds:

```swift
GuardHero(model: model)
    .frame(height: 148)
    .border(Color.blue, width: 2)   // ← 看 frame 边界

HStack(...)
    .frame(height: 190)
    .border(Color.green, width: 1)  // ← 看容器边界
```

- Red background = card 实际绘制范围
- Colored border = frame 约束边界
- 两者不重合 → 内容没撑满 frame（缺 `.frame(maxHeight: .infinity)`）
- 容器边框间有间隙 → spacing 或布局结构问题

### Debug workflow

When user reports a visual layout issue:

1. **Apply debug modifications**: swap `amberGlassCard` → red bg, add `.border()` to containers as needed
2. **Build & package**: `zsh Scripts/make-app-bundle.sh`
3. **Do NOT commit** debug code
4. User inspects the visual, reports findings (which borders have gaps, which backgrounds don't fill)
5. Revert all debug changes with `git checkout -- Sources/`
6. Fix the actual root cause based on findings
7. Build & package for final verification

### Notch at HStack inner column boundary

The HStack splits into two columns (left `VStack` + `NowPlayingCard`). At the top edge (GuardHero boundary), both cards' inner-facing corners (cr=14) create a small notch. This is an inherent artifact of per-card rounded corners with zero spacing — distinguishable from the bottom boundary (HStack → ActivityTimeline) because ActivityTimeline is full-width and its straight top edge fills the notch.

## Tests

```sh
swift run LidMuteCoreBehaviorTests
```
