# LidMute Adaptive Visual Theme Implementation Plan

> **For agentic workers:** This plan is executed inline in the current `feature/lidmute` branch. No subagents or additional worktrees are permitted.

**Goal:** Improve LidMute's light/dark visual hierarchy and readability while preserving the existing Amber + Liquid Glass identity and layout contract.

**Architecture:** Add a single adaptive semantic theme layer in `AmberVisualTheme.swift`, then migrate cards and controls to consume semantic surfaces, text colors, borders, and status colors. Extend the existing visual-principles script as a source-level regression guard, and verify both packaged app output and the existing core behavior suite.

**Tech Stack:** Swift 6, SwiftUI, macOS 26 Liquid Glass with macOS 15 fallback, Bash source checks, project packaging script.

## Global Constraints

- Only modify the current `feature/lidmute` branch.
- Do not create subagents or additional worktrees.
- Preserve `VisualLayoutMetrics` dimensions, zero card spacing, timeline row height, and existing business behavior.
- Do not add dependencies or user-facing theme settings.
- Final verification must use `zsh Scripts/make-app-bundle.sh` and verify `dist/LidMute.app`.

### Task 1: Add failing visual-theme source checks

**Files:**
- Modify: `Scripts/check-visual-principles.sh`

- [ ] Add checks requiring semantic theme members (`surfacePrimary`, `surfaceSecondary`, `surfaceTertiary`, `primaryText`, `secondaryText`, `border`) in `AmberVisualTheme.swift`.
- [ ] Add checks requiring `ContentView.swift` and `LiquidGlassControls.swift` to reference the semantic theme layer.
- [ ] Add a guard rejecting new direct `.background(.white.opacity(` usage in those files.
- [ ] Run `bash Scripts/check-visual-principles.sh` and confirm it fails because the new members do not exist yet.

### Task 2: Implement adaptive theme tokens and atmosphere

**Files:**
- Modify: `Sources/LidMuteApp/AmberVisualTheme.swift`

- [ ] Add `@Environment(\.colorScheme)`-driven semantic colors through a `ThemePalette` value and `AmberVisualTheme.palette(for:)`.
- [ ] Define light surfaces as stable warm-neutral layers and dark surfaces as deep blue-gray layers; keep Amber, Sea Glass, Mist Blue, and danger as semantic accents.
- [ ] Reduce light-mode atmosphere saturation/opacity and keep dark-mode glow restrained.
- [ ] Update `AmberGlassCardModifier` and `AmberGlassSurfaceModifier` to consume palette surfaces and borders while retaining macOS 26 and fallback branches.
- [ ] Run the source check and confirm it still fails only for component references not yet migrated.

### Task 3: Migrate dashboard cards and status hierarchy

**Files:**
- Modify: `Sources/LidMuteApp/ContentView.swift`

- [ ] Read the palette from `@Environment(\.colorScheme)` in the affected view components.
- [ ] Replace fixed white/black surfaces and low-contrast secondary-only status treatments in HeaderBar, GuardHero, MetricPill, AutomationCard, SimulationCard, NowPlayingCard, AudioProcessRow, and CardTitle.
- [ ] Give Hero status and primary guard action the strongest semantic treatment.
- [ ] Make active audio and empty audio states explicitly distinguishable.
- [ ] Improve timeline title/detail/time hierarchy and replace fixed white divider color with the adaptive border token.
- [ ] Preserve all existing actions, labels, accessibility labels, layout sizes, and event rendering logic.

### Task 4: Migrate Liquid Glass controls

**Files:**
- Modify: `Sources/LidMuteApp/LiquidGlassControls.swift`

- [ ] Add color-scheme-aware surface and foreground behavior to `LiquidGlassButtonStyle` and `LiquidGlassIconButtonStyle`.
- [ ] Keep emphasized buttons tied to the supplied semantic tint and make disabled controls retain a visible boundary without global opacity washout.
- [ ] Preserve button dimensions, press scale animation, interactive glass behavior, and fallback materials.

### Task 5: Verify source, build, package, and UI

**Files:**
- No source changes expected unless verification exposes a concrete issue.

- [ ] Run `bash Scripts/check-visual-principles.sh` and expect `PASS visual principle source checks`.
- [ ] Run `swift run --disable-sandbox --triple arm64-apple-macosx26.0 LidMuteCoreBehaviorTests` with the repository's writable cache settings.
- [ ] Run `zsh Scripts/make-app-bundle.sh` from the repository root.
- [ ] Verify `codesign --verify --deep --strict --verbose=2 dist/LidMute.app`.
- [ ] Inspect the packaged app in light and dark appearance at 900×680 and confirm Hero state, active audio, timeline readability, disabled controls, and card hierarchy.
- [ ] Run `git diff --check` and report the final branch and commit status.
