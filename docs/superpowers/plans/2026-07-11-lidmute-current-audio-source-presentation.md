# LidMute Current Audio Source Presentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace PID-centric current-audio rows with Chrome tab titles or macOS application names and reuse the same presentation rules in the event timeline.

**Architecture:** `LidMuteCore` owns a pure `AudioSourcePresentation` model that formats a process and optional Chrome tab. `AppViewModel` tracks the latest Chrome evidence only while CoreAudio reports an active Chrome output process, and publishes presentation rows for SwiftUI. `ContentView` renders those rows and uses the same formatter for timeline events.

**Tech Stack:** Swift 6, SwiftUI, AppKit/CoreAudio, existing JSONL Chrome bridge.

## Global Constraints

- Preserve the existing `tab_audio_started` Chrome extension protocol.
- PID is only a final fallback and is not shown as a fixed trailing field.
- Historical Chrome evidence must not appear as currently playing after Chrome output stops.
- Preserve all existing Liquid Glass and media-key worktree changes.

---

### Task 1: Shared audio-source presentation model

**Files:**
- Modify: `Sources/LidMuteCore/Models.swift`
- Test: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Consumes: `AudioProcess`, `ChromeTabEvidence`
- Produces: `AudioSourcePresentation.init(process:chromeTab:)`, `AudioSourcePresentation.init(event:)`

- [ ] **Step 1: Write failing behavior tests**

Add assertions that a Chrome tab produces title `优酷` and subtitle containing `Google Chrome`, a regular process produces its app name and bundle ID, and an unidentified process falls back to `PID 2468`.

- [ ] **Step 2: Verify RED**

Run:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-26 SWIFTPM_CACHE_PATH=/tmp/lidmute-swiftpm-cache swift run --disable-sandbox --scratch-path /tmp/lidmute-audio-source-red --triple arm64e-apple-macosx26.0 LidMuteCoreBehaviorTests
```

Expected: compilation fails because `AudioSourcePresentation` does not exist.

- [ ] **Step 3: Implement the pure formatter**

Add an `Equatable`, `Identifiable`, `Sendable` model containing `id`, `title`, `subtitle`, `symbolName`, `process`, and `chromeTab`. Apply the priority order Chrome title, application name, then PID fallback. The event initializer delegates to the process/tab initializer so card and timeline cannot diverge.

- [ ] **Step 4: Verify GREEN**

Run the command from Step 2 and expect every behavior test to print `PASS` with exit code 0.

### Task 2: Live-source lifecycle and SwiftUI rendering

**Files:**
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Modify: `Sources/LidMuteApp/ContentView.swift`
- Test: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Consumes: `AudioSourcePresentation.init(process:chromeTab:)`
- Produces: `AppViewModel.currentAudioSources: [AudioSourcePresentation]`

- [ ] **Step 1: Add lifecycle coverage**

Test the pure source builder with an active Chrome process plus evidence, then without an active Chrome process, expecting the Chrome tab title only in the first result.

- [ ] **Step 2: Verify RED**

Run the behavior-test command and expect failure because the source builder does not exist.

- [ ] **Step 3: Implement ViewModel state**

Store the latest decoded `ChromeTabEvidence`. Rebuild `currentAudioSources` after every audio poll and inbox drain. Pass Chrome evidence only to the active Chrome process; clear it as soon as no active Chrome output process exists.

- [ ] **Step 4: Render shared presentation**

Change `NowPlayingCard` to iterate over `currentAudioSources`, display `title`, `subtitle`, and `symbolName`, and remove the fixed trailing PID. Change `EventTimelineRow` to render `AudioSourcePresentation(event:)` beneath event detail when process or tab evidence exists.

- [ ] **Step 5: Verify and package**

Run Core behavior tests, Chrome extension tests, and an arm64e macOS 26.5 build. Package with:

```bash
LIDMUTE_BUILD_ROOT=/tmp/lidmute-audio-source-build/arm64e-apple-macosx/debug zsh Scripts/make-app-bundle.sh
codesign --force --deep --sign - dist/LidMute.app
codesign --verify --deep --strict --verbose=2 dist/LidMute.app
```

Expected: all tests and build exit 0; `dist/LidMute.app` satisfies its designated requirement.
