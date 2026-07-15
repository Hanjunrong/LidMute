# LidMute Aurora Glass Visual Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace LidMute's flat card and icon treatment with the approved Aurora Glass system while preserving layout metrics and all business behavior.

**Architecture:** Centralize gradients, glass depth, optical borders, shadows, and symbol tiles in `AmberVisualTheme.swift`; views select semantic roles instead of defining one-off surfaces. Keep native macOS 26 `glassEffect` paths and provide a material/gradient fallback for macOS 15, then generate the app icon deterministically from the existing Swift script.

**Tech Stack:** Swift 6, SwiftUI, AppKit drawing, macOS 15 compatibility, macOS 26 Liquid Glass APIs, shell source-contract checks.

## Global Constraints

- Work only on the current `feature/lidmute` branch.
- Do not use subagents.
- Preserve `VisualLayoutMetrics.cardSpacing = 0` and all current layout dimensions.
- Preserve the content-fill → padding → card-background modifier order.
- Keep `LSMinimumSystemVersion` at `15.0`.
- Use native `glassEffect` only behind `#available(macOS 26.0, *)`.
- Do not add third-party dependencies or change business, Chrome, audio, lid-monitoring, or event-storage behavior.
- Build and package only through `zsh Scripts/make-app-bundle.sh`.

---

### Task 1: Encode the Aurora visual contract

**Files:**
- Modify: `Scripts/check-visual-principles.sh`
- Modify: `Sources/LidMuteApp/AmberVisualTheme.swift`

**Interfaces:**
- Produces: `AuroraCardRole`, `AuroraSymbolTile`, `View.amberGlassCard(role:padding:cornerRadius:)`.
- Preserves: `AmberThemePalette`, `AmberAtmosphere`, `TightCardDeck`, and `View.amberGlassSurface` call sites.

- [ ] **Step 1: Add failing source-contract checks**

Extend `Scripts/check-visual-principles.sh` with exact checks for `enum AuroraCardRole`, `struct AuroraSymbolTile`, `LinearGradient`, and the role-aware `amberGlassCard(role:` signature. Reject the obsolete `Color.black.opacity(0.22)` deck fill.

- [ ] **Step 2: Run the visual check and verify RED**

Run: `bash Scripts/check-visual-principles.sh`

Expected: exit 1 with `FAIL visual principle: Aurora cards must expose semantic surface roles`.

- [ ] **Step 3: Implement the shared Aurora system**

Add semantic palette tokens for optical highlights and shadows, `AuroraCardRole` cases (`hero`, `standard`, `media`, `timeline`), per-role `LinearGradient` values, a role-aware card modifier, and `AuroraSymbolTile(systemImage:tint:secondaryTint:size:cornerRadius:)`.

The macOS 26 path applies:

```swift
.background(role.gradient(palette: palette), in: shape)
.glassEffect(.regular.tint(role.glassTint(palette: palette)), in: .rect(cornerRadius: cornerRadius))
.overlay(role.opticalBorder(palette: palette, shape: shape))
.shadow(color: palette.cardShadow, radius: role.shadowRadius, y: role.shadowY)
```

The macOS 15 fallback applies the same gradient, `.ultraThinMaterial`, optical border, and shadow without referencing unavailable APIs.

- [ ] **Step 4: Run the visual check and verify GREEN**

Run: `bash Scripts/check-visual-principles.sh`

Expected: `PASS visual principle source checks`.

- [ ] **Step 5: Commit the shared visual system**

```bash
git add Scripts/check-visual-principles.sh Sources/LidMuteApp/AmberVisualTheme.swift
git commit -m "feat: add Aurora Glass visual system"
```

### Task 2: Apply semantic cards and modern symbol tiles

**Files:**
- Modify: `Scripts/check-visual-principles.sh`
- Modify: `Sources/LidMuteApp/ContentView.swift`

**Interfaces:**
- Consumes: `AuroraCardRole` and `AuroraSymbolTile` from Task 1.
- Produces: Hero `.hero`, automatic/simulation `.standard`, current sound `.media`, and timeline `.timeline` card assignments.

- [ ] **Step 1: Add failing usage checks**

Require `.amberGlassCard(role: .hero`, `.standard`, `.media`, `.timeline`, plus `AuroraSymbolTile(` in `ContentView.swift`. Reject the old Header `RoundedRectangle(...).fill(AmberVisualTheme.amber.opacity(0.18))` icon tile.

- [ ] **Step 2: Run the visual check and verify RED**

Run: `bash Scripts/check-visual-principles.sh`

Expected: exit 1 because semantic role call sites are not present.

- [ ] **Step 3: Apply card roles without changing frames**

Update only the existing card modifier calls:

```swift
.amberGlassCard(role: .hero, padding: 0, cornerRadius: 14)
.amberGlassCard(role: .standard, padding: 0, cornerRadius: 14)
.amberGlassCard(role: .media, padding: 0, cornerRadius: 14)
.amberGlassCard(role: .timeline, padding: 0, cornerRadius: 14)
```

Do not change any `.frame(height:)`, `VStack(spacing:)`, `HStack(spacing:)`, or `VisualLayoutMetrics` expression.

- [ ] **Step 4: Replace flat icon wells**

Use `AuroraSymbolTile` for the Header shield, card titles, audio process rows, and timeline event rows. Keep SF Symbol names and accessibility labels unchanged; pass existing semantic colors as `tint`.

- [ ] **Step 5: Run the visual check and core behavior tests**

Run: `bash Scripts/check-visual-principles.sh`

Expected: `PASS visual principle source checks`.

Run: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache swift run --disable-sandbox --scratch-path /tmp/lidmute-test-build --triple arm64-apple-macosx26.0 LidMuteCoreBehaviorTests`

Expected: exit 0 and all `PASS` lines, including visual layout assertions.

- [ ] **Step 6: Commit semantic card and icon usage**

```bash
git add Scripts/check-visual-principles.sh Sources/LidMuteApp/ContentView.swift
git commit -m "feat: apply Aurora cards and symbol tiles"
```

### Task 3: Give controls consistent glass depth

**Files:**
- Modify: `Scripts/check-visual-principles.sh`
- Modify: `Sources/LidMuteApp/LiquidGlassControls.swift`

**Interfaces:**
- Consumes: adaptive palette tokens from Task 1.
- Preserves: `LiquidGlassButtonStyle` and `LiquidGlassIconButtonStyle` initializers and all call sites.

- [ ] **Step 1: Add a failing control-depth check**

Require a shared `AuroraControlChrome` modifier in `LiquidGlassControls.swift`, and require `.interactive()` to remain in both macOS 26 button paths.

- [ ] **Step 2: Run the visual check and verify RED**

Run: `bash Scripts/check-visual-principles.sh`

Expected: exit 1 with the missing control chrome message.

- [ ] **Step 3: Implement shared optical chrome**

Add a private `AuroraControlChrome` modifier that supplies a subtle tint gradient, top highlight, semantic outline, and pressed-state shadow. Apply it before the native interactive glass effect and use the same visible hierarchy in the fallback path. Keep existing sizes, padding, scale animations, enablement, and labels.

- [ ] **Step 4: Run the visual check and verify GREEN**

Run: `bash Scripts/check-visual-principles.sh`

Expected: `PASS visual principle source checks`.

- [ ] **Step 5: Commit the control treatment**

```bash
git add Scripts/check-visual-principles.sh Sources/LidMuteApp/LiquidGlassControls.swift
git commit -m "feat: deepen Aurora glass controls"
```

### Task 4: Redesign and validate the app icon

**Files:**
- Modify: `Scripts/check-visual-principles.sh`
- Modify: `Scripts/render-app-icon.swift`
- Modify: `Assets/AppIcon-1024.png`

**Interfaces:**
- Consumes: existing AppKit drawing helpers and packaging icon pipeline.
- Produces: deterministic 1024×1024 Aurora Glass icon source.

- [ ] **Step 1: Add failing icon-source checks**

Require the render script to contain `shield.fill` and `speaker.slash.fill`; reject `apple.logo`. This makes the approved guard/mute semantics executable and prevents the old trademark-dependent design from returning.

- [ ] **Step 2: Run the visual check and verify RED**

Run: `bash Scripts/check-visual-principles.sh`

Expected: exit 1 because the current renderer still contains `apple.logo`.

- [ ] **Step 3: Implement the icon renderer**

Replace the literal laptop illustration with a layered rounded-square glass composition: Aurora background gradient, blurred amber/aqua light fields, translucent inner plate, `shield.fill`, and a foreground `speaker.slash.fill` badge. Preserve transparent outer canvas, high-resolution antialiasing, and deterministic PNG output.

- [ ] **Step 4: Render and validate dimensions**

Run: `swift Scripts/render-app-icon.swift Assets/AppIcon-1024.png`

Expected: `Wrote .../Assets/AppIcon-1024.png`.

Run: `sips -g pixelWidth -g pixelHeight -g hasAlpha Assets/AppIcon-1024.png`

Expected: width 1024, height 1024, alpha present.

- [ ] **Step 5: Inspect the generated icon**

Open `Assets/AppIcon-1024.png` with the image viewer and confirm the shield and muted-speaker badge remain legible at full size. Generate a 64px preview under `/tmp` and confirm it remains recognizable.

- [ ] **Step 6: Run the visual check and commit**

Run: `bash Scripts/check-visual-principles.sh`

Expected: `PASS visual principle source checks`.

```bash
git add Scripts/check-visual-principles.sh Scripts/render-app-icon.swift Assets/AppIcon-1024.png
git commit -m "feat: redesign LidMute Aurora app icon"
```

### Task 5: Build, package, and hand off for visual acceptance

**Files:**
- Verify: `dist/LidMute.app`
- Verify: `dist/LidMute.app/Contents/Resources/AppIcon.icns`

**Interfaces:**
- Consumes: all implementation tasks.
- Produces: freshly built, signed application bundle for user acceptance.

- [ ] **Step 1: Run the complete source and behavior verification**

Run: `bash Scripts/check-visual-principles.sh`

Run: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache swift run --disable-sandbox --scratch-path /tmp/lidmute-test-build --triple arm64-apple-macosx26.0 LidMuteCoreBehaviorTests`

Expected: both exit 0.

- [ ] **Step 2: Package from fresh source**

Run: `zsh Scripts/make-app-bundle.sh`

Expected: `Created /Users/han/temp/workspace/LidMute/dist/LidMute.app`.

- [ ] **Step 3: Verify source freshness and signature**

Run: `find Sources -type f -newer dist/LidMute.app/Contents/MacOS/LidMute -print`

Expected: no output.

Run: `codesign --verify --deep --strict --verbose=2 dist/LidMute.app`

Expected: valid on disk and satisfies designated requirement.

- [ ] **Step 4: Launch the packaged app for acceptance**

Run: `open dist/LidMute.app`

Expected: the newly packaged app opens from `dist`, showing Aurora gradients, role-specific glass depth, and the redesigned icon for user review.

- [ ] **Step 5: Record final evidence**

Run: `git status --short --branch && git log -6 --oneline --decorate`

Expected: `feature/lidmute` is active and implementation commits are visible; report any intentionally uncommitted packaging artifacts separately.
