# LidMute Automation Controls And Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Disable automation controls while the guard is off, persist valid automation changes immediately, remove the apply button, and move simulation controls into a separate Liquid Glass card.

**Architecture:** A focused Core preferences store owns durable automation values and preserves the last valid schedule. `AppViewModel` keeps editable text separate from the effective schedule and exposes explicit mutation methods used by SwiftUI bindings and `onChange`. `ContentView` reorganizes cards without changing media command behavior.

**Tech Stack:** Swift 6, Foundation `UserDefaults`, SwiftUI, existing Liquid Glass theme, executable behavior tests, shell smoke checks.

## Global Constraints

- Enabling the guard alone must not alter current audio unless the current lid/night state already requires protection.
- Night protection still requires guard enabled, automation enabled, display asleep, and Beijing time in range.
- Automation controls are disabled while the guard is off; saved values are retained.
- Valid changes save immediately; invalid `HH:mm` text never overwrites the last valid schedule.
- Remove the apply button and place simulation controls in a separate glass card.
- Do not change previous/play-pause/next implementation or copy.
- Do not perform GUI or sound acceptance; the user owns final manual acceptance.

---

### Task 1: Durable Valid Automation Preferences

**Files:**
- Create: `Sources/LidMuteCore/NightProtectionPreferences.swift`
- Modify: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Produces: `NightProtectionConfiguration` and `NightProtectionPreferences` with `load()`, `saveEnabled(_:)`, and `saveSchedule(startText:endText:)`.

- [ ] Write a failing behavior test using a unique `UserDefaults` suite. Verify defaults are `false`, `00:00`, `08:00`; enabled saves independently; a valid schedule persists; an invalid schedule returns `false` and leaves the valid schedule intact.
- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteCoreBehaviorTests` and confirm RED because the preference types do not exist.
- [ ] Implement `NightProtectionConfiguration(enabled:startText:endText:)` and a `NightProtectionPreferences` class backed by injected `UserDefaults`. Validate exact `HH:mm` with hours `0...23` and minutes `0...59`; only write both schedule keys after both values validate.
- [ ] Re-run the behavior executable and confirm GREEN.
- [ ] Commit with `git commit -m "feat: persist valid night protection settings"`.

---

### Task 2: Immediate ViewModel Saving And Effective Schedule

**Files:**
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Verify: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Consumes: `NightProtectionPreferences` from Task 1.
- Produces: `setNightScheduleEnabled(_:)` and `nightScheduleTextChanged()` for SwiftUI; removes `applyNightSchedule()`.

- [ ] Replace direct `UserDefaults` access with `NightProtectionPreferences`; load the initial configuration and initialize a private `effectiveNightSchedule` from the persisted valid values.
- [ ] Add `setNightScheduleEnabled(_ enabled: Bool)`, which updates the published value, immediately saves the flag, and recalculates protection.
- [ ] Add `nightScheduleTextChanged()`, which saves and replaces `effectiveNightSchedule` only when both text values are valid, then recalculates protection. Invalid text keeps the old effective schedule and displays `时间格式应为 HH:mm`.
- [ ] Change `refreshNightProtection()` to use `effectiveNightSchedule` for protection decisions while using editable text validity only for status copy.
- [ ] Remove `applyNightSchedule()` and the direct `settings` property.
- [ ] Run the Swift build and behavior executable; confirm enabling-guard and night-protection regressions remain green.
- [ ] Commit with `git commit -m "feat: auto-save night protection configuration"`.

---

### Task 3: Separate Liquid Glass Simulation Card

**Files:**
- Modify: `Sources/LidMuteApp/ContentView.swift`
- Modify: `Sources/LidMuteApp/LidMuteApp.swift`
- Modify: `Scripts/run-smoke-check.sh`
- Modify: `docs/LidMute-中文设计说明.md`

**Interfaces:**
- Consumes: ViewModel methods from Task 2 and existing Liquid Glass button/card styles.
- Produces: disabled automation controls, no apply button, and standalone `SimulationCard`.

- [ ] In `AutomationCard`, bind the toggle through `Binding(get:set:)` to `setNightScheduleEnabled(_:)`, call `nightScheduleTextChanged()` from both text fields with `onChange`, disable the toggle and fields when `model.isEnabled == false`, and remove the apply button, divider, and simulation controls.
- [ ] Create `SimulationCard` with `CardTitle(title: "模拟测试", subtitle: "独立验证合盖状态", systemImage: "testtube.2")`, the existing close/open/reset controls, Liquid Glass styles, disabled states, help, and accessibility values.
- [ ] Place `SimulationCard` in its own row between the automation/current-sound row and `ActivityTimeline`; keep `AutomationCard` and `NowPlayingCard` equal width.
- [ ] Increase the scene default height only as needed to prevent the additional compact card from crowding the timeline; preserve a minimum width of 900.
- [ ] Add smoke assertions that `ContentView.swift` contains no `应用时间`, contains `private struct SimulationCard`, and contains automation `.disabled(!model.isEnabled)` bindings.
- [ ] Update the Chinese guide with immediate persistence, disabled controls, separate simulation card, and user-owned manual acceptance.
- [ ] Run `zsh Scripts/run-smoke-check.sh`; expect all Swift/Chrome tests, build, double bundle, permission checks, and new UI source assertions to pass.
- [ ] Run `git diff --check` and commit with `git commit -m "feat: reorganize automation and simulation controls"`.

---

## Final Verification

- Run `zsh Scripts/run-smoke-check.sh` once more after all commits.
- Verify `git status --short` is clean.
- Do not launch the app or operate Chrome/media controls.
- Report the built app path and explicitly leave GUI, audio, and media-button acceptance to the user.
