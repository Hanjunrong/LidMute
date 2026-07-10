# LidMute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a testable macOS menu-bar app that mutes only built-in speakers during a protected lid-closed interval and records process- and Chrome-tab-level audio events.

**Architecture:** `LidMuteCore` contains pure models, JSONL persistence, protocol-backed adapters, the protection state machine, and the Chrome bridge decoder. `LidMuteApp` supplies SwiftUI/AppKit UI and production IOKit/CoreAudio adapters. `LidMuteNativeHost` implements Chrome's framed-JSON stdio protocol and appends validated frames to the app-private inbox. A Manifest V3 extension emits tab-audibility events.

**Tech Stack:** Swift 6.3, Swift Package Manager, SwiftUI, AppKit, Foundation, IOKit, CoreAudio, JavaScript (Node built-in test runner), Manifest V3.

## Global Constraints

- macOS only; build against the current macOS 26 SDK with no external Swift package dependencies.
- Use public IOKit, CoreAudio, SwiftUI, AppKit, and Foundation APIs only.
- Only built-in speakers are muted; no external output device is modified.
- Store detailed events indefinitely in local JSON Lines and expose one confirmed clear action.
- Chrome tab events include title, URL, window/tab IDs, audible/muted transitions, extension session ID, and correlation status.
- Native Messaging uses `tabs`, `nativeMessaging`, and `storage`; the host accepts only the registered extension ID.
- Tests precede production code for every independently testable behavior.

---

## File Structure

- `Package.swift`: products and targets for core, app, native host, and tests.
- `Sources/LidMuteCore/Models.swift`: Codable domain models and protocol contracts.
- `Sources/LidMuteCore/EventStore.swift`: append/load/clear JSONL persistence.
- `Sources/LidMuteCore/ProtectionCoordinator.swift`: main-actor protection state machine.
- `Sources/LidMuteCore/ChromeProtocol.swift`: Chrome tab frame decoding and event construction.
- `Sources/LidMuteApp/LidMuteApp.swift`: application lifecycle and menu-bar wiring.
- `Sources/LidMuteApp/SystemAudioController.swift`: CoreAudio production adapter.
- `Sources/LidMuteApp/SystemLidMonitor.swift`: IOKit production adapter.
- `Sources/LidMuteApp/ChromeBridgeServer.swift`: Unix-domain socket server.
- `Sources/LidMuteApp/ContentView.swift`: liquid-glass dashboard and activity log.
- `Sources/LidMuteNativeHost/main.swift`: Chrome native-message framing and socket forwarder.
- `Tests/LidMuteCoreTests/*.swift`: core TDD coverage.
- `ChromeExtension/manifest.json`: MV3 permissions and worker declaration.
- `ChromeExtension/service-worker.js`: tab snapshot/listener/Native Messaging bridge.
- `ChromeExtension/service-worker.test.mjs`: Node tests for serialized events.
- `Scripts/register-chrome-host.sh`: user-level native-host manifest registration.
- `Scripts/run-smoke-check.sh`: build and deterministic simulation verification.
- `README.md`: install, Chrome extension loading, bridge registration, and manual acceptance.

### Task 1: Package and Domain Contracts

**Files:**
- Create: `Package.swift`
- Create: `Sources/LidMuteCore/Models.swift`
- Create: `Tests/LidMuteCoreTests/ModelsTests.swift`

**Interfaces:**
- Produces `ProtectionState`, `AudioDevice`, `AudioProcess`, `ChromeTabEvidence`, `LidMuteEvent`, `AudioControlling`, and `EventStoring`.

- [ ] **Step 1: Write the failing model test**

```swift
func testChromeEvidenceRoundTripsWithoutLosingURL() throws {
    let evidence = ChromeTabEvidence(sessionID: "s", windowID: 1, tabID: 2,
                                     index: 0, title: "优酷", url: "https://v.youku.com",
                                     audible: true, muted: false, isActive: false,
                                     isPinned: false, isIncognito: false)
    let decoded = try JSONDecoder().decode(ChromeTabEvidence.self,
        from: JSONEncoder().encode(evidence))
    XCTAssertEqual(decoded.url, "https://v.youku.com")
}
```

- [ ] **Step 2: Run the test and verify the package has no target yet**

Run: `swift test --filter ModelsTests/testChromeEvidenceRoundTripsWithoutLosingURL`

Expected: FAIL because `LidMuteCore` and the model types do not exist.

- [ ] **Step 3: Add the package manifest and minimal Codable model**

```swift
// Package.swift target outline
.library(name: "LidMuteCore", targets: ["LidMuteCore"]),
.executable(name: "LidMuteApp", targets: ["LidMuteApp"]),
.executable(name: "LidMuteNativeHost", targets: ["LidMuteNativeHost"])

public struct ChromeTabEvidence: Codable, Equatable, Sendable {
    public let sessionID: String
    public let windowID: Int
    public let tabID: Int
    public let index: Int
    public let title: String
    public let url: String
    public let audible: Bool
    public let muted: Bool
    public let isActive: Bool
    public let isPinned: Bool
    public let isIncognito: Bool
}
```

- [ ] **Step 4: Run the test and verify it passes**

Run: `swift test --filter ModelsTests/testChromeEvidenceRoundTripsWithoutLosingURL`

Expected: PASS with one executed test.

### Task 2: Durable Event Store

**Files:**
- Create: `Sources/LidMuteCore/EventStore.swift`
- Create: `Tests/LidMuteCoreTests/EventStoreTests.swift`

**Interfaces:**
- Consumes `LidMuteEvent` and `EventStoring` from Task 1.
- Produces `JSONLineEventStore(url:)`, `append(_:)`, `load()`, and `clear()`.

- [ ] **Step 1: Write failing persistence and clear tests**

```swift
func testAppendReloadAndClear() throws {
    let url = temporaryURL()
    let store = JSONLineEventStore(url: url)
    try store.append(event(kind: .muteEnforced))
    XCTAssertEqual(try store.load().count, 1)
    try store.clear()
    XCTAssertTrue(try store.load().isEmpty)
}
```

- [ ] **Step 2: Run the failing event-store test**

Run: `swift test --filter EventStoreTests/testAppendReloadAndClear`

Expected: FAIL because `JSONLineEventStore` does not exist.

- [ ] **Step 3: Implement append-only JSONL persistence with malformed-line recovery**

```swift
public final class JSONLineEventStore: EventStoring, Sendable {
    public func append(_ event: LidMuteEvent) throws {
        let data = try JSONEncoder.lidMute.encode(event) + Data([0x0A])
        try data.append(to: url)
    }
    public func load() throws -> [LidMuteEvent] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap {
            try? JSONDecoder.lidMute.decode(LidMuteEvent.self, from: Data($0.utf8))
        }
    }
}
```

- [ ] **Step 4: Run all core persistence tests**

Run: `swift test --filter EventStoreTests`

Expected: PASS, including append/reload/clear/malformed-line cases.

### Task 3: Protection State Machine

**Files:**
- Create: `Sources/LidMuteCore/ProtectionCoordinator.swift`
- Create: `Tests/LidMuteCoreTests/ProtectionCoordinatorTests.swift`

**Interfaces:**
- Consumes `AudioControlling`, `EventStoring`, `AudioDevice`, and `AudioProcess`.
- Produces `@MainActor final class ProtectionCoordinator` with `setEnabled(_:)`, `receiveLidState(closed:)`, and `receiveAudioSnapshot(_:)`.

- [ ] **Step 1: Write failing close/mute/restore tests with a fake controller**

```swift
func testCloseMutesBuiltInSpeakerAndOpenRestoresCapturedState() async throws {
    let audio = FakeAudioController(device: .builtIn(volume: 0.72, muted: false))
    let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
    await coordinator.setEnabled(true)
    await coordinator.receiveLidState(closed: true)
    XCTAssertEqual(audio.lastAppliedMute, true)
    await coordinator.receiveLidState(closed: false)
    XCTAssertEqual(audio.lastAppliedMute, false)
    XCTAssertEqual(audio.lastAppliedVolume, 0.72)
}
```

- [ ] **Step 2: Run the failing coordinator test**

Run: `swift test --filter ProtectionCoordinatorTests/testCloseMutesBuiltInSpeakerAndOpenRestoresCapturedState`

Expected: FAIL because `ProtectionCoordinator` does not exist.

- [ ] **Step 3: Implement the minimal main-actor state machine**

```swift
public func receiveLidState(closed: Bool) async {
    guard enabled else { return }
    if closed { try await armAndMute() } else { try await restoreIfNeeded() }
}

private func armAndMute() async throws {
    guard let device = try await audio.builtInSpeaker() else { return record(.error) }
    savedState = try await audio.captureState(of: device)
    try await audio.enforceSilence(on: device)
    state = .protecting
    record(.muteEnforced)
}
```

- [ ] **Step 4: Add and pass re-enforcement and zero-volume fallback tests**

Run: `swift test --filter ProtectionCoordinatorTests`

Expected: PASS for close/open, newly active process, unsupported mute fallback, disabled guard, and missing-device cases.

### Task 4: Chrome Event Protocol and Correlation

**Files:**
- Create: `Sources/LidMuteCore/ChromeProtocol.swift`
- Create: `Tests/LidMuteCoreTests/ChromeProtocolTests.swift`

**Interfaces:**
- Consumes `ChromeTabEvidence` and `ProtectionCoordinator`.
- Produces `ChromeBridgeFrame.decode(_:)` and `receiveChromeEvidence(_:)`.

- [ ] **Step 1: Write a failing test for a newly audible Youku tab**

```swift
func testAudibleChromeFrameCreatesTabLevelEvent() async throws {
    let frame = #"{"type":"tab-audible","sessionId":"s","tab":{"id":9,"windowId":3,"index":1,"title":"优酷","url":"https://v.youku.com","audible":true,"muted":false,"active":false,"pinned":false,"incognito":false}}"#
    let event = try ChromeBridgeFrame.decode(Data(frame.utf8)).event
    XCTAssertEqual(event.chromeTab?.tabID, 9)
    XCTAssertEqual(event.chromeTab?.url, "https://v.youku.com")
}
```

- [ ] **Step 2: Run the failing protocol test**

Run: `swift test --filter ChromeProtocolTests/testAudibleChromeFrameCreatesTabLevelEvent`

Expected: FAIL because `ChromeBridgeFrame` does not exist.

- [ ] **Step 3: Decode only supported versioned frames and mark correlation honestly**

```swift
public enum ChromeBridgeFrame {
    public static func decode(_ data: Data) throws -> DecodedChromeFrame {
        let frame = try JSONDecoder.lidMute.decode(WireFrame.self, from: data)
        guard frame.version == 1, frame.type == "tab-audible", frame.tab.audible else {
            throw ChromeProtocolError.unsupportedFrame
        }
        return DecodedChromeFrame(event: .chromeAudible(frame.tab.evidence(sessionID: frame.sessionID)))
    }
}
```

- [ ] **Step 4: Run Chrome protocol tests**

Run: `swift test --filter ChromeProtocolTests`

Expected: PASS for audible, muted, malformed, unsupported-version, and browser-observed-only cases.

### Task 5: macOS Production Adapters and Socket Server

**Files:**
- Create: `Sources/LidMuteApp/SystemAudioController.swift`
- Create: `Sources/LidMuteApp/SystemLidMonitor.swift`
- Create: `Sources/LidMuteApp/ChromeBridgeServer.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes `AudioControlling`, `LidStateMonitoring`, and `ChromeBridgeFrame`.
- Produces CoreAudio device lookup/muting, IOKit lid notifications, and a localhost Unix-domain socket listener.

- [ ] **Step 1: Add compile-focused adapter contracts before implementation**

```swift
final class SystemAudioController: AudioControlling {
    func builtInSpeaker() async throws -> AudioDevice? { fatalError("not implemented") }
    func enforceSilence(on device: AudioDevice) async throws { fatalError("not implemented") }
}
```

- [ ] **Step 2: Run the build and verify the deliberate adapter stubs fail only at runtime, not compilation**

Run: `swift build`

Expected: PASS compilation; no UI launch is performed in this step.

- [ ] **Step 3: Replace stubs with public CoreAudio and IOKit calls**

```swift
let address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
// Enumerate devices, select built-in transport/name, then set kAudioDevicePropertyMute
// or kAudioDevicePropertyVolumeScalar only for the selected device.
```

- [ ] **Step 4: Build and run simulation-backed adapter smoke tests**

Run: `swift build && swift test`

Expected: PASS build and all core tests; production adapters are exercised only through the app's explicit simulation control until manual device verification.

### Task 6: Native App UI and Menu-Bar Lifecycle

**Files:**
- Create: `Sources/LidMuteApp/LidMuteApp.swift`
- Create: `Sources/LidMuteApp/ContentView.swift`
- Create: `Sources/LidMuteApp/AppViewModel.swift`

**Interfaces:**
- Consumes `ProtectionCoordinator`, `ChromeBridgeServer`, and loaded `LidMuteEvent` records.
- Produces a SwiftUI app with `MenuBarExtra`, persisted guard switch, diagnostics, log filtering, copy, and clear confirmation.

- [ ] **Step 1: Add a failing view-model test for simulation state**

```swift
func testSimulatedCloseUpdatesVisibleStatus() async {
    let model = AppViewModel(coordinator: fakeCoordinator)
    await model.simulateLidClosed()
    XCTAssertEqual(model.statusText, "正在保护内建扬声器")
}
```

- [ ] **Step 2: Run the failing UI-state test**

Run: `swift test --filter AppViewModelTests/testSimulatedCloseUpdatesVisibleStatus`

Expected: FAIL because `AppViewModel` does not exist.

- [ ] **Step 3: Implement an intentional liquid-glass dashboard**

```swift
struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.38), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
    }
}
```

- [ ] **Step 4: Run UI-state tests and compile the app executable**

Run: `swift test && swift build --product LidMuteApp`

Expected: PASS tests and a linked `.build/debug/LidMuteApp` executable.

### Task 7: Chrome Extension and Native Host

**Files:**
- Create: `ChromeExtension/manifest.json`
- Create: `ChromeExtension/service-worker.js`
- Create: `ChromeExtension/service-worker.test.mjs`
- Create: `Sources/LidMuteNativeHost/main.swift`
- Create: `Scripts/register-chrome-host.sh`

**Interfaces:**
- Consumes the `ChromeBridgeFrame` v1 schema and Unix socket path emitted by the app.
- Produces Manifest V3 event forwarding and Chrome length-prefixed native messaging.

- [ ] **Step 1: Write the failing JavaScript serialization test**

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { toAudibleFrame } from './service-worker.js';

test('serializes title URL and audible transition', () => {
  const frame = toAudibleFrame({ id: 9, windowId: 3, index: 1, title: '优酷',
    url: 'https://v.youku.com', audible: true, mutedInfo: { muted: false } });
  assert.equal(frame.type, 'tab-audible');
  assert.equal(frame.tab.url, 'https://v.youku.com');
});
```

- [ ] **Step 2: Run the failing extension test**

Run: `node --test ChromeExtension/service-worker.test.mjs`

Expected: FAIL because the worker module does not exist.

- [ ] **Step 3: Implement MV3 listener and host framing**

```json
{"manifest_version":3,"name":"LidMute Chrome Monitor","version":"0.1.0","permissions":["tabs","nativeMessaging"],"background":{"service_worker":"service-worker.js","type":"module"}}
```

```js
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.audible === true) nativePort.postMessage(toAudibleFrame(tab));
});
```

- [ ] **Step 4: Run extension tests and build the native host**

Run: `node --test ChromeExtension/service-worker.test.mjs && swift build --product LidMuteNativeHost`

Expected: PASS Node tests and compile the native host.

### Task 8: Installation, Smoke Check, and Documentation

**Files:**
- Create: `Scripts/run-smoke-check.sh`
- Create: `README.md`
- Modify: `docs/LidMute-中文设计说明.md`

**Interfaces:**
- Consumes built products, Chrome extension folder, and native-host registration script.
- Produces deterministic build/test/simulation commands and an accurate manual deployment guide.

- [ ] **Step 1: Write the smoke script assertions before the script body**

```sh
test -x .build/debug/LidMuteApp
test -x .build/debug/LidMuteNativeHost
test -f ChromeExtension/manifest.json
node --test ChromeExtension/service-worker.test.mjs
swift test
```

- [ ] **Step 2: Run the incomplete smoke script**

Run: `bash Scripts/run-smoke-check.sh`

Expected: FAIL until products, manifest, and tests have been created.

- [ ] **Step 3: Implement the smoke script and concise deployment guide**

```sh
#!/bin/zsh
set -euo pipefail
swift build
swift test
node --test ChromeExtension/service-worker.test.mjs
test -x .build/debug/LidMuteApp
test -x .build/debug/LidMuteNativeHost
```

- [ ] **Step 4: Run final automated verification and manual checklist**

Run: `bash Scripts/run-smoke-check.sh`

Expected: exit code 0 after Swift build, Swift tests, Node extension tests, and binary/manifest checks.

Manual verification: launch `LidMuteApp`, enable the guard, use Simulate Lid Closed, inspect the activity log, load the unpacked extension in Chrome, open a media page, confirm a tab-level event, use Simulate Lid Open, and confirm state restoration.

## Plan Self-Review

- Spec coverage: Tasks 1-4 implement durable, detailed protection and Chrome evidence; Task 5 isolates system integration; Task 6 provides the requested UI/background behavior; Tasks 7-8 deliver the Chrome layer and verifiable installation.
- Placeholder scan: no deferred implementation markers are present; every task names files, interfaces, test commands, and expected outcomes.
- Type consistency: all app and host code shares `ChromeTabEvidence`/`ChromeBridgeFrame`; only `ProtectionCoordinator` controls muting and restoration.
