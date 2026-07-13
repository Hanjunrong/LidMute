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

- All card spacing is zero (`VisualLayoutMetrics.cardSpacing = 0`)
- Cards share a unified `TightCardDeck` background — no per-card rounded corners, strokes, or glass effects that would create seams at card boundaries
- Only the timeline card consumes extra window height

## Tests

```sh
swift run LidMuteCoreBehaviorTests
```
