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
- **Content fills frame**: Every card's content view must have `.frame(maxHeight: .infinity)` BEFORE `.padding()`. Without this, intrinsic content height < padded height → amberGlassCard is centered within the frame, creating visible gaps between cards.
- **Only the timeline card consumes extra window height** — all other cards have fixed heights from `VisualLayoutMetrics`.

### Key layout patterns

```
// Every card must follow this modifier order:
ContentHStack/VStack(...)
    .frame(maxHeight: .infinity)    // ← REQUIRED: fills padded area
    .padding(10)                     // internal padding (8 for NowPlayingCard)
    .amberGlassCard(padding: 0, cornerRadius: 14)  // card background + stroke
```

Without `.frame(maxHeight: .infinity)`, the content's intrinsic height is smaller than the frame height (e.g. GuardHero content ≈ 106pt + padding = 126pt vs frame 148pt). SwiftUI centers the undersized content within the frame, leaving transparent gaps at top/bottom.

### Notch at HStack inner column boundary

The HStack splits into two columns (left `VStack` + `NowPlayingCard`). At the top edge (GuardHero boundary), both cards' inner-facing corners (cr=14) create a small notch. This is an inherent artifact of per-card rounded corners with zero spacing — distinguishable from the bottom boundary (HStack → ActivityTimeline) because ActivityTimeline is full-width and its straight top edge fills the notch.

## Tests

```sh
swift run LidMuteCoreBehaviorTests
```
