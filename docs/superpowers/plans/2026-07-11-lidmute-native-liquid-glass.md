# LidMute Native Liquid Glass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the generated LidMute macOS app visibly use native SwiftUI Liquid Glass for its background, surfaces, and controls on macOS 26 while preserving the macOS 15 fallback.

**Architecture:** Keep the existing SwiftUI theme and button-style boundaries. Add a native glass container/panel at the composition root, strengthen the shared card and control modifiers, and apply the same surface treatment to status pills and time fields. No model or behavior changes.

**Tech Stack:** Swift 6.3, SwiftUI, macOS 26 SDK, macOS 15 deployment target, Swift Package Manager.

## Global Constraints

- Keep `Package.swift` at `.macOS(.v15)`.
- Gate every Liquid Glass API with `#available(macOS 26.0, *)`.
- Preserve all existing user actions, disabled states, accessibility labels, and uncommitted user changes outside the visual files.

---

### Task 1: Strengthen shared native glass surfaces

**Files:**
- Modify: `Sources/LidMuteApp/AmberVisualTheme.swift`
- Modify: `Sources/LidMuteApp/LiquidGlassControls.swift`

**Interfaces:**
- Preserve `AmberAtmosphere`, `amberGlassCard`, `LiquidGlassButtonStyle`, and `LiquidGlassIconButtonStyle` public call sites.
- Add a reusable internal `AmberGlassSurface` modifier for compact pills and fields.

- [ ] Add a macOS 26 branch that uses `.glassEffect(.regular.tint(...), in:)` for compact surfaces, retaining `.ultraThinMaterial` fallback.
- [ ] Ensure button glass remains interactive and keeps existing press/disabled animation.
- [ ] Run `swift build --package-path LidMute --target LidMuteApp` and confirm compilation.

### Task 2: Apply glass grouping and surfaces to the dashboard

**Files:**
- Modify: `Sources/LidMuteApp/ContentView.swift`

**Interfaces:**
- Keep `ContentView` and all nested view names unchanged.
- Keep all model actions and accessibility behavior unchanged.

- [ ] Wrap the dashboard content in a macOS 26 `GlassEffectContainer` with a spacing value that prevents neighboring cards from merging.
- [ ] Add a native glass backdrop panel over `AmberAtmosphere` behind the dashboard content.
- [ ] Apply the shared glass surface to the header status capsule, metric pills, and both time fields.
- [ ] Build the app and inspect the diff for visual-only changes.

### Task 3: Generate and verify the app bundle

**Files:**
- No source changes expected.

- [ ] Run `Scripts/run-smoke-check.sh`.
- [ ] Run `Scripts/make-app-bundle.sh`.
- [ ] Verify `dist/LidMute.app/Contents/MacOS/LidMute` is executable and `Info.plist` keeps `LSMinimumSystemVersion` 15.0.
- [ ] Run the core behavior executable and report exact build/test results.
