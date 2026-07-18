# LidMute Control Center Glass Implementation Plan

> **For agentic workers:** Execute inline in the current session. The user explicitly requested no subagents.

**Goal:** Implement the selected Control Center Glass visual system across LidMute cards, controls, typography, and accessibility behavior without changing business logic.

**Architecture:** Extend the existing semantic theme and shared control styles, then apply centralized typography tokens in `ContentView`. Preserve all `VisualLayoutMetrics` contracts and validate the new visual system through the existing static preflight plus core behavior tests.

**Tech Stack:** Swift 6, SwiftUI, macOS 15 fallback, macOS 26 Liquid Glass, Bash preflight checks.

## Global Constraints

- Keep `VisualLayoutMetrics.cardSpacing = 0` and all existing height contracts.
- Keep macOS 26 native glass behind `#available(macOS 26.0, *)` with macOS 15–25 fallback.
- Do not change business logic, app icon, Chrome communication, audio behavior, or event persistence.
- Do not add third-party dependencies.
- Do not perform visual acceptance; the user performs final visual testing.

---

### Task 1: Encode Control Center Glass contracts

**Files:**
- Modify: `Scripts/check-visual-principles.sh`

**Interfaces:**
- Consumes: source text in the three SwiftUI files.
- Produces: failing assertions for `ControlCenterTypography`, critical spring response, and reduced-motion handling.

- [ ] Add grep assertions for the shared typography enum, `.spring(response: 0.30, dampingFraction: 1.0)`, and `accessibilityReduceMotion`.
- [ ] Run `bash Scripts/check-visual-principles.sh` and confirm it fails because the new visual contract is absent.

### Task 2: Implement typography and material hierarchy

**Files:**
- Modify: `Sources/LidMuteApp/AmberVisualTheme.swift`
- Modify: `Sources/LidMuteApp/ContentView.swift`

**Interfaces:**
- Produces: `ControlCenterTypography` fonts and updated semantic card/material appearance.
- Consumes: existing `AuroraCardRole`, `AmberThemePalette`, and `amberGlassCard` APIs.

- [ ] Add centralized system-font tokens for brand, hero, card title, body, caption, and numeric text.
- [ ] Increase Hero/media material depth while calming the timeline surface and preserving adaptive light/dark tokens.
- [ ] Replace scattered rounded/heavy typography with shared tokens and size-specific tracking.
- [ ] Run the visual preflight and confirm only control-interaction assertions remain failing.

### Task 3: Implement physical button response and accessibility

**Files:**
- Modify: `Sources/LidMuteApp/LiquidGlassControls.swift`

**Interfaces:**
- Consumes: `LiquidGlassButtonStyle` and `LiquidGlassIconButtonStyle` call sites unchanged.
- Produces: immediate press scaling, critical spring return, and reduced-motion fallback.

- [ ] Read `accessibilityReduceMotion` in both shared button styles.
- [ ] Replace fixed `easeOut` animations with `spring(response: 0.30, dampingFraction: 1.0)` and disable scale motion when reduced motion is enabled.
- [ ] Preserve `.interactive()` on both macOS 26 native glass paths.
- [ ] Run the visual preflight and confirm it passes.

### Task 4: Verify and package

**Files:**
- Verify: `Tests/LidMuteCoreBehavior/main.swift`
- Verify: `dist/LidMute.app`

**Interfaces:**
- Produces: a freshly built and signed app bundle for user testing.

- [ ] Run core behavior tests with explicit SDK, writable caches, scratch path, and `arm64e-apple-macosx26.0` triple; expect all tests to pass.
- [ ] Run `env SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk LIDMUTE_BUILD_TRIPLE=arm64e-apple-macosx26.0 zsh Scripts/make-app-bundle.sh`; expect `Created .../dist/LidMute.app`.
- [ ] Run `codesign --verify --deep --strict --verbose=2 dist/LidMute.app`; expect successful verification.
- [ ] Report the branch, changed files, automated evidence, and the unperformed user-owned visual checks.
