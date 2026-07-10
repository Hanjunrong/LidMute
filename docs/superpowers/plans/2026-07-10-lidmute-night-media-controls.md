# LidMute 夜间静音与媒体控制 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit lid/night protection policies, configurable Beijing-time screen-sleep muting, current audio process visibility, system media controls, resettable simulation state, and the latest compatible glass UI.

**Architecture:** Keep `ProtectionCoordinator` as the only muting state machine. Add pure `NightSchedule` policy logic and adapter boundaries for display sleep and system media keys. `AppViewModel` coordinates timers and published UI state; SwiftUI remains a presentation layer.

**Tech Stack:** Swift 6, macOS 15+, SwiftUI, AppKit, CoreAudio, IOKit, CoreGraphics, executable behavior tests, Node Chrome extension tests.

## Global Constraints

- Only the built-in speaker route may be muted.
- Enabling/disabling the guard must not change active audio; lid/night transitions may mute.
- Night schedule defaults to Beijing time `00:00-08:00` and must be configurable.
- Media controls are system-level macOS media key events.
- Use `.glassEffect` when the SDK exposes it and material fallback otherwise.
- Preserve permanent local logs and tab-level Chrome evidence.

### Task 1: Core Policy Tests

**Files:**
- Modify: `Tests/LidMuteCoreBehavior/main.swift`
- Modify: `Sources/LidMuteCore/Models.swift`
- Create: `Sources/LidMuteCore/NightSchedule.swift`

**Interfaces:**
- `NightSchedule(startMinutes:endMinutes:timeZoneIdentifier:) -> NightSchedule`
- `isActive(at:) -> Bool`
- `resetSimulationState()` remains an AppViewModel operation and is tested through observable state where possible.

- [ ] Write failing tests for guard enable/disable preserving `FakeAudioController` state, active night schedule across midnight, schedule end restoration, and schedule validation.
- [ ] Run `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache swift run --disable-sandbox --scratch-path /tmp/lidmute-next LidMuteCoreBehaviorTests` and confirm the new expectations fail for missing APIs/behavior.
- [ ] Implement the pure schedule type and extend fake audio assertions without changing production routing yet.
- [ ] Run the behavior executable and confirm schedule tests pass while existing Chrome and protection tests remain green.

### Task 2: Protection and System Adapters

**Files:**
- Modify: `Sources/LidMuteCore/ProtectionCoordinator.swift`
- Modify: `Sources/LidMuteCore/Models.swift`
- Modify: `Sources/LidMuteApp/SystemLidMonitor.swift`
- Create: `Sources/LidMuteApp/SystemDisplayMonitor.swift`
- Create: `Sources/LidMuteApp/SystemMediaController.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`

**Interfaces:**
- `ProtectionCoordinator.receiveDisplaySleep(_:)`
- `ProtectionCoordinator.receiveNightSchedule(isActive:)`
- `SystemDisplayMonitor.start()` and `stop()` callbacks use `Bool` sleeping state.
- `SystemMediaController.send(_ command: MediaCommand)` sends previous/next/play-pause system events.

- [ ] Add failing coordinator tests for “enable does not mute”, “night sleep mutes”, “night end restores when not closed”, “night end does not restore while closed”, and “disable restores all captured state”.
- [ ] Implement protection source tracking so lid and night protection share one safe mute state and do not restore while another source remains active.
- [ ] Add display sleep notifications and a 30-second boundary timer using `Asia/Shanghai` schedule evaluation.
- [ ] Implement media key event injection with explicit error logging and no dependency on the target process.
- [ ] Run core tests and compile the macOS target.

### Task 3: UI and Configuration

**Files:**
- Modify: `Sources/LidMuteApp/ContentView.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Modify: `Sources/LidMuteApp/LidMuteApp.swift`
- Modify: `docs/LidMute-中文设计说明.md`
- Modify: `README.md`

**Interfaces:**
- Published `currentAudioProcesses`, `nightScheduleEnabled`, `nightStart`, `nightEnd`, `isDisplaySleeping`, and `simulationState` feed the view.
- View actions call `resetSimulationState()`, `setNightScheduleEnabled(_:)`, `setNightSchedule(start:end:)`, and `sendMediaCommand(_:)`.

- [ ] Add UI-facing behavior assertions or deterministic ViewModel seams for reset state and default schedule.
- [ ] Implement the current audio card with process metadata and system media buttons.
- [ ] Implement schedule controls with default `00:00`/`08:00`, enable switch, and current sleep/night status.
- [ ] Apply layered glass background with guarded `.glassEffect` usage and `.ultraThinMaterial` fallback.
- [ ] Update Chinese documentation with the new rules and limitations.

### Task 4: Verification and Packaging

**Files:**
- Modify: `Scripts/run-smoke-check.sh`
- Modify: `Scripts/make-app-bundle.sh` only if new resources are needed.

- [ ] Run the full smoke check, including Swift behavior tests, Chrome tests, app build, and two consecutive bundle builds.
- [ ] Verify `Info.plist`, app icon, no nested Chrome extension, and clean `git diff --check`.
- [ ] Launch the app for a cold-start UI check without enabling real speaker mutation.
- [ ] Commit with `feat: add night guard and system media controls`.
