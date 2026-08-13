# LidMute Protection and Recovery Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make LidMute's physical/simulated protection, route changes, durable speaker recovery, startup gate, and normal termination fail safe without changing the existing visual design.

**Architecture:** Preserve `ProtectionCoordinator` as the protection state machine, but give physical lid, simulation, and night policy independent inputs. Add UID-based audio resolution and a durable recovery journal behind small interfaces, then integrate them through a lifecycle runtime that completes recovery before monitors or Chrome consumption can start.

**Tech Stack:** Swift 6, SwiftPM, XCTest, Foundation, CoreAudio, IOKit, AppKit, SwiftUI.

## Global Constraints

- The branch starts from approved design commit `6b85f44` on `fix/lidmute-reliability-hardening`.
- The minimum supported version remains macOS 15.
- Do not add third-party runtime dependencies.
- Do not change the Control Center Glass visual layout, card spacing, window sizing, or app icon.
- Remove only automatic protection-triggered media commands; user-initiated previous, next, and play/pause controls remain available.
- Physical lid, simulation, and night protection are independent sources whose effective protection is their logical OR.
- Never capture, mute, or restore Bluetooth, USB, display, HDMI, or any output that cannot be revalidated as the built-in speaker.
- Persist a recovery snapshot successfully before the first speaker mutation, and delete it only after a verified successful restore.
- Recovery may claim “still silent” only after read-back verification; an unknown safety state must remain explicit and block ordinary termination.
- Use the project packaging script for final artifacts; direct `swift build` is not a final deliverable.
- Follow red-green-refactor: every production behavior change starts with a failing test whose failure is observed.

---

### Task 1: Replace the executable behavior harness with standard XCTest targets

**Files:**
- Modify: `Package.swift`
- Delete after migration: `Tests/LidMuteCoreBehavior/main.swift`
- Create: `Tests/LidMuteCoreTests/TestDoubles.swift`
- Create: `Tests/LidMuteCoreTests/ExistingBehaviorTests.swift`
- Modify: `Scripts/run-smoke-check.sh`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: existing public interfaces from `LidMuteCore`.
- Produces: `.testTarget(name: "LidMuteCoreTests", dependencies: ["LidMuteCore"])`; reusable `FakeAudioController` and `MemoryEventStore`; `swift test` as the canonical Core test command.

- [ ] **Step 1: Prove the current package has no standard test target**

Run before changing any file:

```bash
swift test --filter ExistingBehaviorTests/testNightScheduleHandlesBeijingTimeAcrossMidnight
```

Expected: FAIL with SwiftPM reporting that no tests are found or that no matching test target/test exists. This is the real RED: the repository does not expose its existing behavior checks through `swift test`.

- [ ] **Step 2: Add one discovered XCTest and replace the executable target**

Create `Tests/LidMuteCoreTests/ExistingBehaviorTests.swift` with:

```swift
import XCTest
@testable import LidMuteCore

final class ExistingBehaviorTests: XCTestCase {
    func testNightScheduleHandlesBeijingTimeAcrossMidnight() throws {
        let schedule = NightSchedule(startMinutes: 23 * 60, endMinutes: 7 * 60)
        let inside = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T16:30:00Z"))
        let outside = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))
        XCTAssertTrue(schedule.isActive(at: inside))
        XCTAssertFalse(schedule.isActive(at: outside))
    }
}
```

Replace the `LidMuteCoreBehaviorTests` executable target/product in `Package.swift` with `.testTarget(name: "LidMuteCoreTests", dependencies: ["LidMuteCore"], path: "Tests/LidMuteCoreTests")`. The old unreferenced harness may remain temporarily while its methods are migrated, but it must not share a target path or be used to manufacture a failure.

- [ ] **Step 3: Run the discovery test and observe GREEN**

Run:

```bash
swift test --filter ExistingBehaviorTests/testNightScheduleHandlesBeijingTimeAcrossMidnight
```

Expected: PASS with exactly one selected XCTest. This proves discovery before the bulk migration.

- [ ] **Step 4: Migrate the existing harness into XCTest methods**

Move every behavior from `Tests/LidMuteCoreBehavior/main.swift` into XCTest methods grouped in `ExistingBehaviorTests`. Replace manual `guard ... else { throw BehaviorTestError... }` assertions with `XCTAssertEqual`, `XCTAssertTrue`, `XCTAssertFalse`, and `XCTUnwrap`. Move fakes into `TestDoubles.swift`:

```swift
final class MemoryEventStore: EventStoring, @unchecked Sendable {
    private(set) var events: [LidMuteEvent] = []
    func append(_ event: LidMuteEvent) throws { events.append(event) }
    func load() throws -> [LidMuteEvent] { events }
    func clear() throws { events.removeAll() }
}

final class FakeAudioController: AudioControlling, @unchecked Sendable {
    var device = AudioDevice(id: 7, uid: "built-in-a", name: "MacBook Speakers", isBuiltIn: true)
    var capturedState = AudioDeviceState(muted: false, volume: 0.72, usedVolumeFallback: false)
    private(set) var mutations: [String] = []
    var activeProcesses: [AudioProcess] = []

    func builtInSpeaker() throws -> AudioDevice? { device }
    func captureState(of device: AudioDevice) throws -> AudioDeviceState { capturedState }
    func enforceSilence(on device: AudioDevice) throws { mutations.append("silence:\(device.uid)") }
    func restore(_ state: AudioDeviceState, on device: AudioDevice) throws { mutations.append("restore:\(device.uid)") }
    func activeOutputProcesses() throws -> [AudioProcess] { activeProcesses }
}
```

Delete `Tests/LidMuteCoreBehavior/main.swift` and remove the executable product entirely.

- [ ] **Step 5: Run all migrated Core tests**

Run:

```bash
swift test
```

Expected: PASS, with XCTest discovering all 30 previously printed Core behavior checks plus the Chrome deduplicator behavior. No `no tests found` message is allowed.

- [ ] **Step 6: Update the repository test contract and smoke script**

Change `Scripts/run-smoke-check.sh` from `swift run ... LidMuteCoreBehaviorTests` to:

```zsh
swift test --disable-sandbox --scratch-path "$scratch"
```

Change the `AGENTS.md` Tests command to `swift test`. Keep packaging through `zsh Scripts/make-app-bundle.sh` unchanged.

- [ ] **Step 7: Verify the canonical test and smoke entry points**

Run:

```bash
swift test
zsh Scripts/run-smoke-check.sh
```

Expected: both exit 0; smoke output includes XCTest pass output, 2 passing Node tests, visual-principle checks, and `PASS LidMute smoke check`.

- [ ] **Step 8: Commit the test migration**

```bash
git add Package.swift Tests Scripts/run-smoke-check.sh AGENTS.md
git commit -m "test: adopt standard SwiftPM test target" \
  -m "Constraint: Preserve all existing behavior checks while making swift test authoritative" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate"
```

---

### Task 2: Remove automatic protection-triggered media toggles

**Files:**
- Modify: `Sources/LidMuteCore/ProtectionCoordinator.swift`
- Modify: `Sources/LidMuteCore/Models.swift`
- Modify: `Sources/LidMuteCore/EventPresentation.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Create: `Tests/LidMuteCoreTests/AutomaticMediaControlTests.swift`
- Modify: `Tests/LidMuteCoreTests/ExistingBehaviorTests.swift`

**Interfaces:**
- Consumes: Task 1's XCTest target and fakes.
- Produces: a `ProtectionCoordinator` with no `onMediaPauseRequest`, `recordMediaPauseResult`, debounce state, or automatic media-pause event kinds; manual `MediaCommand` and `SystemMediaController.send(_:)` remain unchanged.

- [ ] **Step 1: Add failing tests asserting protection never emits a media effect**

Create `AutomaticMediaControlTests.swift`:

```swift
import XCTest
@testable import LidMuteCore

@MainActor
final class AutomaticMediaControlTests: XCTestCase {
    func testProtectionInputsDoNotExposeAutomaticMediaCallback() {
        let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: MemoryEventStore())
        XCTAssertNil(Mirror(reflecting: coordinator).children.first { $0.label == "onMediaPauseRequest" })
    }

    func testChromeEvidenceDuringProtectionOnlyRecordsEvidenceAndSilence() {
        let audio = FakeAudioController()
        audio.activeProcesses = [.init(pid: 42, name: "Google Chrome", bundleID: "com.google.Chrome", executablePath: nil, launchDate: nil, isOutputActive: true)]
        let store = MemoryEventStore()
        let coordinator = ProtectionCoordinator(audio: audio, store: store)
        coordinator.setEnabled(true)
        coordinator.receiveLidState(closed: true)
        coordinator.receiveChromeEvidence(.fixture(audible: true, incognito: false))
        XCTAssertFalse(store.events.contains { $0.kind == .mediaPauseRequested || $0.kind == .mediaPauseRequestFailed })
        XCTAssertTrue(store.events.contains { $0.kind == .chromeTabAudible })
    }

    func testManualMediaDescriptorsRemainAvailable() {
        XCTAssertEqual(MediaKeyEventDescriptor.events(for: .playPause).count, 2)
    }
}
```

Add a `ChromeTabEvidence.fixture(audible:incognito:)` helper in the test target only.

- [ ] **Step 2: Run the new tests and observe RED**

Run:

```bash
swift test --filter AutomaticMediaControlTests
```

Expected: FAIL because `onMediaPauseRequest` still exists and protected Chrome evidence records or emits automatic pause requests.

- [ ] **Step 3: Delete automatic pause state and callbacks from Core**

Remove from `ProtectionCoordinator`:

- `onMediaPauseRequest`;
- `mediaPauseDebounce`, `lastMediaPauseRequestAt`, and `now` constructor parameters used only by debounce;
- `requestPauseForActiveChrome`, `emitMediaPauseRequest`, and `recordMediaPauseResult`;
- calls from physical/simulated lid, night, audio snapshot, and Chrome evidence paths.

Remove automatic-only types and event kinds from `Models.swift`: `MediaPauseTrigger`, `MediaPauseRequest`, `.mediaPauseRequested`, and `.mediaPauseRequestFailed`. Keep `MediaCommand` and `MediaKeyEventDescriptor`.

- [ ] **Step 4: Remove automatic callback wiring from AppViewModel**

Delete the coordinator callback assignment and `handleMediaPauseRequest(_:)`. Keep `sendMediaCommand(_:)` and `SystemMediaController` for explicit user button actions.

Update `EventPresentation` and migrated tests so deleted event kinds no longer compile or appear in expected labels.

- [ ] **Step 5: Run focused and full tests**

```bash
swift test --filter AutomaticMediaControlTests
swift test
```

Expected: PASS. Focused tests prove Chrome/lid/night paths never produce automatic media events, and the full suite proves manual descriptor behavior remains.

- [ ] **Step 6: Commit the media-safety change**

```bash
git add Sources Tests
git commit -m "fix: remove automatic global media toggles" \
  -m "Constraint: Retain user-initiated media controls while protection relies only on speaker silence" \
  -m "Rejected: Keep best-effort playPause | a global toggle can start unrelated media" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate"
```

---

### Task 3: Separate physical lid, simulation, and night protection sources

**Files:**
- Modify: `Sources/LidMuteCore/Models.swift`
- Modify: `Sources/LidMuteCore/ProtectionCoordinator.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Create: `Tests/LidMuteCoreTests/ProtectionSourceStateTests.swift`
- Modify: `Tests/LidMuteCoreTests/TestDoubles.swift`

**Interfaces:**
- Consumes: Task 2's media-effect-free coordinator.
- Produces: `ProtectionSource.physicalLid`, `.simulation`, `.night`; `SimulationLidState.closed/opened/reset`; `receivePhysicalLid(_:)`, `receiveSimulation(_:)`, and existing `receiveNightProtection(_:)`.

- [ ] **Step 1: Write the source-interleaving regression matrix**

Create `ProtectionSourceStateTests.swift`:

```swift
import XCTest
@testable import LidMuteCore

@MainActor
final class ProtectionSourceStateTests: XCTestCase {
    func testSimulationOpenCannotReleasePhysicalProtection() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receiveSimulation(.opened)
        XCTAssertEqual(coordinator.state, .protecting)
        XCTAssertEqual(audio.mutations.filter { $0.hasPrefix("restore:") }.count, 0)
    }

    func testPhysicalOpenCannotReleaseClosedSimulation() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receiveSimulation(.closed)
        coordinator.receivePhysicalLid(closed: false)
        XCTAssertEqual(coordinator.state, .protecting)
    }

    func testResetOnlyRemovesSimulationSource() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receiveSimulation(.closed)
        coordinator.receiveSimulation(.reset)
        XCTAssertEqual(coordinator.state, .protecting)
    }

    func testRepeatedAndOutOfOrderInputsDoNotRepeatMutations() {
        let audio = FakeAudioController()
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        coordinator.setEnabled(true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receivePhysicalLid(closed: true)
        coordinator.receiveSimulation(.opened)
        coordinator.receiveSimulation(.opened)
        XCTAssertEqual(audio.mutations.filter { $0.hasPrefix("silence:") }.count, 1)
    }
}
```

- [ ] **Step 2: Run the matrix and observe the missing-interface failure**

```bash
swift test --filter ProtectionSourceStateTests
```

Expected: FAIL to compile because `receivePhysicalLid`, `receiveSimulation`, and the independent source cases do not exist.

- [ ] **Step 3: Introduce explicit source types and independent observations**

In `Models.swift` define:

```swift
public enum ProtectionSource: String, Codable, Hashable, Sendable {
    case physicalLid
    case simulation
    case night
}

public enum SimulationLidState: Sendable {
    case closed
    case opened
    case reset
}
```

In `ProtectionCoordinator`, replace `observedLidClosed` with `observedPhysicalLidClosed: Bool?` and `observedSimulation: SimulationLidState?`. Implement `receivePhysicalLid(closed:)` so it changes only `.physicalLid`; implement simulation `.closed` as activate, `.opened` and `.reset` as deactivate `.simulation`, with `.reset` also clearing the observation. Restore only when `activeSources` becomes empty.

- [ ] **Step 4: Update AppViewModel entry points**

Route system monitor callbacks to `receivePhysicalLid`. Route simulation buttons to `receiveSimulation(.closed/.opened/.reset)`. Do not feed simulation values into `latestSystemLidClosed`.

- [ ] **Step 5: Add disable and night-overlap cases**

Extend the test file with:

```swift
func testDisableClearsAllSourcesAndRestoresOnce() {
    let audio = FakeAudioController()
    let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
    coordinator.setEnabled(true)
    coordinator.receivePhysicalLid(closed: true)
    coordinator.receiveSimulation(.closed)
    coordinator.receiveNightProtection(true)
    coordinator.setEnabled(false)
    XCTAssertEqual(coordinator.state, .inactive)
    XCTAssertEqual(audio.mutations.filter { $0.hasPrefix("restore:") }.count, 1)
}
```

- [ ] **Step 6: Run focused tests and the full suite**

```bash
swift test --filter ProtectionSourceStateTests
swift test
```

Expected: PASS, including all interleaving, duplicate input, night overlap, and disable cases.

- [ ] **Step 7: Commit independent protection sources**

```bash
git add Sources Tests
git commit -m "fix: isolate physical and simulated lid sources" \
  -m "Constraint: Simulation must never release an active physical or night source" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate"
```

---

### Task 4: Resolve built-in devices by UID and monitor route changes

**Files:**
- Modify: `Sources/LidMuteCore/Models.swift`
- Modify: `Sources/LidMuteApp/SystemAudioController.swift`
- Create: `Sources/LidMuteApp/SystemAudioRouteMonitor.swift`
- Create: `Sources/LidMuteCore/AudioDeviceResolver.swift`
- Create: `Tests/LidMuteCoreTests/AudioDeviceResolutionTests.swift`
- Modify: `Tests/LidMuteCoreTests/TestDoubles.swift`

**Interfaces:**
- Consumes: Task 1's test target; Task 3 will later consume route-change retry.
- Produces: `AudioControlling.resolveBuiltInSpeaker(uid: String?) throws -> AudioDevice?`; `AudioDeviceResolver` for classification; `SystemAudioRouteMonitor.start()/stop()` emitting a coalesced change signal.

- [ ] **Step 1: Write UID resolution tests using a pure candidate resolver**

Create `AudioDeviceResolver.swift` with declarations only, then create tests:

```swift
import XCTest
@testable import LidMuteCore

final class AudioDeviceResolutionTests: XCTestCase {
    func testExplicitUIDFindsBuiltInSpeakerWhenExternalRouteIsDefault() {
        let candidates = [
            AudioDeviceCandidate(device: .init(id: 9, uid: "external-b", name: "HDMI", isBuiltIn: false), isDefault: true, isInternalTransport: false, dataSourceName: "HDMI"),
            AudioDeviceCandidate(device: .init(id: 11, uid: "built-in-a", name: "MacBook Speakers", isBuiltIn: true), isDefault: false, isInternalTransport: true, dataSourceName: "MacBook Speakers")
        ]
        XCTAssertEqual(AudioDeviceResolver.resolve(candidates, uid: "built-in-a")?.id, 11)
    }

    func testNilUIDRejectsExternalDefault() {
        let candidate = AudioDeviceCandidate(device: .init(id: 9, uid: "external-b", name: "HDMI", isBuiltIn: false), isDefault: true, isInternalTransport: false, dataSourceName: "HDMI")
        XCTAssertNil(AudioDeviceResolver.resolve([candidate], uid: nil))
    }

    func testMatchingUIDStillRequiresInternalTransportAndSpeakerDataSource() {
        let impostor = AudioDeviceCandidate(device: .init(id: 15, uid: "built-in-a", name: "Display", isBuiltIn: false), isDefault: false, isInternalTransport: false, dataSourceName: "DisplayPort")
        XCTAssertNil(AudioDeviceResolver.resolve([impostor], uid: "built-in-a"))
    }
}
```

- [ ] **Step 2: Run resolver tests and observe RED**

```bash
swift test --filter AudioDeviceResolutionTests
```

Expected: FAIL because `AudioDeviceCandidate` and resolver behavior are not implemented.

- [ ] **Step 3: Implement the pure resolver and extend AudioControlling**

Define `AudioDeviceCandidate` as a Sendable value with device, default flag, transport flag, and data-source name. `AudioDeviceResolver.resolve` filters for internal transport plus a localized speaker data source (`speaker`, `扬声器`, or `喇叭`), then matches explicit UID or the default candidate.

Replace `builtInSpeaker()` in `AudioControlling` with:

```swift
func resolveBuiltInSpeaker(uid: String?) throws -> AudioDevice?
```

Update fakes and coordinator call sites with `uid: nil` until Task 6 adds explicit recovery resolution.

- [ ] **Step 4: Implement SystemAudioController device enumeration**

Use `kAudioHardwarePropertyDevices` to enumerate candidates, read each UID, transport, name, and output data source, mark the current default output, then call the pure resolver. Do not return a device if any required classification property cannot be read. Re-enumerate on every call so an old AudioObjectID is never trusted across a route change.

- [ ] **Step 5: Add a route monitor adapter**

Create `SystemAudioRouteMonitor` that registers an `AudioObjectAddPropertyListenerBlock` for `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDevices`. Its small interface is:

```swift
@MainActor
final class SystemAudioRouteMonitor {
    init(onChange: @escaping @MainActor () -> Void)
    func start() throws
    func stop()
}
```

Coalesce callbacks onto `MainActor`; store the exact listener blocks so `stop()` removes them.

- [ ] **Step 6: Run resolver tests and compile the app**

```bash
swift test --filter AudioDeviceResolutionTests
zsh Scripts/make-app-bundle.sh
```

Expected: PASS; packaging exits 0 and contains both `LidMute` and `LidMuteNativeHost`. Manual CoreAudio behavior is not claimed by these pure tests.

- [ ] **Step 7: Commit UID resolution and route monitoring**

```bash
git add Sources Tests
git commit -m "feat: resolve built-in audio routes by UID" \
  -m "Constraint: Never return or mutate an output that cannot be revalidated as the built-in speaker" \
  -m "Confidence: medium" \
  -m "Scope-risk: moderate" \
  -m "Not-tested: Physical route hot-swap on a MacBook"
```

---

### Task 5: Add a durable speaker recovery journal

**Files:**
- Create: `Sources/LidMuteCore/SpeakerRecoverySnapshot.swift`
- Create: `Sources/LidMuteCore/SpeakerRecoveryStore.swift`
- Create: `Sources/LidMuteCore/FileSpeakerRecoveryStore.swift`
- Create: `Tests/LidMuteCoreTests/SpeakerRecoveryStoreTests.swift`
- Modify: `Tests/LidMuteCoreTests/TestDoubles.swift`

**Interfaces:**
- Consumes: `AudioDevice`, `AudioDeviceState`, and `ProtectionSource`.
- Produces: versioned `SpeakerRecoverySnapshot`; typed `SpeakerRecoveryLoadResult`; `SpeakerRecoveryStoring` interface with load/save/mark-finalizing/remove methods; atomic JSON adapter with directory 0700 and file 0600.

- [ ] **Step 1: Write failing model and file-adapter tests**

Create `SpeakerRecoveryStoreTests.swift`:

```swift
import XCTest
@testable import LidMuteCore

final class SpeakerRecoveryStoreTests: XCTestCase {
    func testRoundTripPreservesProtectedSnapshotAndPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSpeakerRecoveryStore(url: root.appending(path: "speaker-recovery.json"))
        let snapshot = SpeakerRecoverySnapshot.fixture(stage: .protected)
        try store.saveBeforeMutation(snapshot)
        XCTAssertEqual(try store.load(), .snapshot(snapshot))
        let directoryMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue)
        let fileMode = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: root.appending(path: "speaker-recovery.json").path)[.posixPermissions] as? NSNumber)?.intValue)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testCorruptAndUnsupportedSnapshotsAreTypedResults() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lidmute-recovery-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "speaker-recovery.json")
        try Data("not-json".utf8).write(to: url)
        XCTAssertEqual(try FileSpeakerRecoveryStore(url: url).load(), .corrupt)
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: url)
        XCTAssertEqual(try FileSpeakerRecoveryStore(url: url).load(), .unsupportedSchema(999))
    }
}
```

- [ ] **Step 2: Run store tests and observe missing types**

```bash
swift test --filter SpeakerRecoveryStoreTests
```

Expected: FAIL to compile because recovery snapshot/store types do not exist.

- [ ] **Step 3: Define the versioned journal model and interface**

Implement:

```swift
public enum SpeakerRecoveryStage: String, Codable, Sendable { case protected, finalizingRestore }

public struct SpeakerRecoverySnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let transactionID: UUID
    public let deviceUID: String
    public let deviceName: String
    public let originalState: AudioDeviceState
    public let stage: SpeakerRecoveryStage
    public let capturedAt: Date
    public let sources: Set<ProtectionSource>
    public let appVersion: String
}

public enum SpeakerRecoveryLoadResult: Equatable, Sendable {
    case none
    case snapshot(SpeakerRecoverySnapshot)
    case corrupt
    case unsupportedSchema(Int)
}

public protocol SpeakerRecoveryStoring: Sendable {
    func load() throws -> SpeakerRecoveryLoadResult
    func saveBeforeMutation(_ snapshot: SpeakerRecoverySnapshot) throws
    func markFinalizingRestore(transactionID: UUID) throws
    func removeCompleted(transactionID: UUID) throws
}
```

The file adapter must reject overwriting a different pending transaction, write to a sibling temporary file, `fsync` it, rename it over the journal, sync the parent directory, and enforce the permissions.

- [ ] **Step 4: Add transaction-ordering tests**

Add tests proving:

```swift
try store.saveBeforeMutation(snapshot)
try store.markFinalizingRestore(transactionID: snapshot.transactionID)
guard case let .snapshot(finalizing) = try store.load() else { return XCTFail("missing snapshot") }
XCTAssertEqual(finalizing.stage, .finalizingRestore)
XCTAssertThrowsError(try store.removeCompleted(transactionID: UUID()))
try store.removeCompleted(transactionID: snapshot.transactionID)
XCTAssertEqual(try store.load(), .none)
```

- [ ] **Step 5: Run focused and full tests**

```bash
swift test --filter SpeakerRecoveryStoreTests
swift test
```

Expected: PASS; test teardown leaves no journal files in the repository.

- [ ] **Step 6: Commit the recovery journal**

```bash
git add Sources/LidMuteCore Tests/LidMuteCoreTests
git commit -m "feat: persist speaker recovery transactions" \
  -m "Constraint: Journal before mutation and remove only after verified restore" \
  -m "Confidence: high" \
  -m "Scope-risk: moderate"
```

---

### Task 6: Integrate fail-safe recovery, route retry, startup gate, and termination handshake

**Files:**
- Create: `Sources/LidMuteCore/SpeakerRecoveryRuntime.swift`
- Create: `Sources/LidMuteCore/ApplicationLifecycleCoordinator.swift`
- Modify: `Sources/LidMuteCore/Models.swift`
- Modify: `Sources/LidMuteCore/ProtectionCoordinator.swift`
- Modify: `Sources/LidMuteApp/SystemAudioController.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Modify: `Sources/LidMuteApp/LidMuteApp.swift`
- Create: `Tests/LidMuteCoreTests/SpeakerRecoveryRuntimeTests.swift`
- Create: `Tests/LidMuteCoreTests/ApplicationLifecycleCoordinatorTests.swift`
- Create: `Tests/LidMuteCoreTests/ProtectionRouteRetryTests.swift`
- Modify: `Tests/LidMuteCoreTests/TestDoubles.swift`

**Interfaces:**
- Consumes: independent protection sources from Task 3, UID resolution from Task 4, and recovery journal from Task 5.
- Produces: `SpeakerRecoveryOutcome`; `AppLifecycleState`; `ShutdownOutcome`; the sole audio-mutation seam `SpeakerProtectionApplying`; `SpeakerRecoveryRuntime.recoverPending()/apply(_:)`; a `ProtectionCoordinator` that computes desired protection actions but never calls `AudioControlling` mutation methods directly; `ProtectionCoordinator.receiveAudioRouteChanged()`; an App delegate termination path using `.terminateLater` and one idempotent shutdown task.

- [ ] **Step 1: Add fail-safe recovery outcome tests with ordered audio operations**

Extend the fake audio controller to script operations and record `resolve`, `capture`, `writeMute`, `writeVolume`, `readState`, and `restore` calls. Create `SpeakerRecoveryRuntimeTests.swift` with:

```swift
import XCTest
@testable import LidMuteCore

final class SpeakerRecoveryRuntimeTests: XCTestCase {
    func testProtectPersistsSnapshotBeforeSilencing() async throws {
        let audio = ScriptedAudioController()
        let store = MemorySpeakerRecoveryStore()
        let runtime = SpeakerRecoveryRuntime(audio: audio, recoveryStore: store, appVersion: "0.1.0")
        _ = await runtime.protect(sources: [.physicalLid])
        XCTAssertEqual(store.operations.first, "save")
        XCTAssertEqual(audio.operations.first, "resolve:nil")
        XCTAssertLessThan(try XCTUnwrap(store.timelineIndex(of: "save")), try XCTUnwrap(audio.timelineIndex(of: "silence")))
    }

    func testRestoreFailureThatCanBeResilencedIsVerifiedSilent() async throws {
        let audio = ScriptedAudioController(failAt: .finalUnmute, readBack: .init(muted: true, volume: 0.72, usedVolumeFallback: false))
        let runtime = SpeakerRecoveryRuntime(audio: audio, recoveryStore: .withPendingFixture(), appVersion: "0.1.0")
        XCTAssertEqual(await runtime.recoverPending(), .failedButVerifiedSilent)
    }

    func testRestoreAndResilenceReadbackFailureIsSafetyUnknown() async throws {
        let audio = ScriptedAudioController(failAt: .readBack)
        let runtime = SpeakerRecoveryRuntime(audio: audio, recoveryStore: .withPendingFixture(), appVersion: "0.1.0")
        XCTAssertEqual(await runtime.recoverPending(), .failedSafetyUnknown)
    }

    func testMismatchedUIDNeverWritesAnotherDevice() async throws {
        let audio = ScriptedAudioController(resolvedUIDs: [:])
        let runtime = SpeakerRecoveryRuntime(audio: audio, recoveryStore: .withPendingFixture(uid: "built-in-a"), appVersion: "0.1.0")
        XCTAssertEqual(await runtime.recoverPending(), .waitingForMatchingDevice)
        XCTAssertFalse(audio.operations.contains { $0.hasPrefix("write") || $0 == "silence" })
    }
}
```

- [ ] **Step 2: Run runtime tests and observe RED**

```bash
swift test --filter SpeakerRecoveryRuntimeTests
```

Expected: FAIL because the runtime, typed outcomes, and stepwise audio mutation interface do not exist.

- [ ] **Step 3: Add stepwise fail-safe audio capabilities**

Extend the Core audio seam so runtime code can enforce ordering and verify results:

```swift
public protocol AudioControlling: AnyObject, Sendable {
    func resolveBuiltInSpeaker(uid: String?) throws -> AudioDevice?
    func captureState(of device: AudioDevice) throws -> AudioDeviceState
    func writeMuted(_ muted: Bool, on device: AudioDevice) throws
    func writeVolume(_ volume: Float, on device: AudioDevice) throws
    func readState(of device: AudioDevice) throws -> AudioDeviceState
    func supportsWritableMute(on device: AudioDevice) -> Bool
    func activeOutputProcesses() throws -> [AudioProcess]
}
```

Implement the SystemAudioController adapter using existing CoreAudio property helpers. Re-resolve by UID before every recovery transaction. Never pass an external candidate through this seam.

Define the only interface through which the coordinator may request a speaker mutation:

```swift
public enum SpeakerProtectionAction: Equatable, Sendable {
    case begin(sources: Set<ProtectionSource>)
    case reinforce
    case end
    case routeChangedWhileProtectionRequired(sources: Set<ProtectionSource>)
}

public protocol SpeakerProtectionApplying: Sendable {
    func apply(_ action: SpeakerProtectionAction) async -> SpeakerRecoveryOutcome
}
```

`SpeakerRecoveryRuntime` is the production adapter. `ProtectionCoordinator` receives `SpeakerProtectionApplying`; it may still ask `AudioControlling` for process evidence through a read-only collaborator, but it must not receive or retain any interface containing `writeMuted`, `writeVolume`, capture, restore, or enforce-silence methods.

- [ ] **Step 4: Implement SpeakerRecoveryRuntime's transaction ordering**

Define:

```swift
public enum SpeakerRecoveryOutcome: Equatable, Sendable {
    case noPendingRecovery
    case restored
    case waitingForMatchingDevice
    case corruptSnapshot
    case unsupportedSnapshot(Int)
    case failedButVerifiedSilent
    case failedSafetyUnknown
}
```

`protect` resolves the default built-in device, captures state, saves `.protected`, then silences. `restore` marks `.finalizingRestore`, writes mute true and verifies it before volume, performs final unmute only after all prior operations pass, verifies the final state, and removes the journal only on exact success. On any error, attempt silence plus read-back and map to the two failure outcomes.

For a `.finalizingRestore` journal, compare the current state first: exact original state means remove and return restored; a known silent intermediate state continues restore; any other state returns `failedSafetyUnknown` without overwriting it.

Delete the old direct-mutation implementation from `ProtectionCoordinator`: `armAndMute`, `restoreForLidOpen`, `restoreForGuardDisable`, `restoreForNightEnd`, `restoreFullState`, `savedState`, `targetDevice`, `disableRestoreState`, and `disableRestoreDevice`. Map source transitions to `SpeakerProtectionAction`: first active source -> `.begin`; active source set remains nonempty -> `.reinforce` only when evidence/route requires it; final source removal or disable -> `.end`; route change with active sources -> `.routeChangedWhileProtectionRequired`. Await the applying result before publishing the final protection state.

- [ ] **Step 5: Add coordinator-path journal-order regression tests**

Add an `OrderedProtectionFixture` whose recovery store and scripted audio adapter share one timeline:

```swift
@MainActor
func testPhysicalLidPathJournalsBeforeActualAudioMutation() async throws {
    let fixture = OrderedProtectionFixture()
    await fixture.coordinator.setEnabled(true)
    await fixture.coordinator.receivePhysicalLid(closed: true)
    XCTAssertLessThan(try XCTUnwrap(fixture.timeline.firstIndex(of: "journal.save")),
                      try XCTUnwrap(fixture.timeline.firstIndex(of: "audio.writeMuted:true")))
}

@MainActor
func testJournalFailureThroughCoordinatorPerformsNoAudioMutation() async {
    let fixture = OrderedProtectionFixture(journalFailure: .diskFull)
    await fixture.coordinator.setEnabled(true)
    await fixture.coordinator.receivePhysicalLid(closed: true)
    XCTAssertFalse(fixture.timeline.contains { $0.hasPrefix("audio.write") })
    XCTAssertEqual(fixture.coordinator.state, .unavailable)
}
```

Add equivalent action-routing assertions for simulation close/open, night begin/end, disable, Chrome/audio reinforce, and route retry. These tests must instantiate the real `SpeakerRecoveryRuntime`; a spy that merely records `.begin` is insufficient for the journal-before-write invariant.

- [ ] **Step 6: Run coordinator journal-order tests and observe RED**

```bash
swift test --filter ProtectionCoordinatorJournalIntegrationTests
```

Expected: FAIL because the coordinator still owns direct audio mutation paths and does not delegate every action to `SpeakerProtectionApplying`.

- [ ] **Step 7: Add startup lifecycle-gate tests**

Create `ApplicationLifecycleCoordinatorTests.swift`:

```swift
@MainActor
final class ApplicationLifecycleCoordinatorTests: XCTestCase {
    func testMonitorsStartOnlyAfterRecoveryIsReady() async {
        let recovery = ControllableRecoveryRuntime(result: .waitingForMatchingDevice)
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)
        await lifecycle.start()
        XCTAssertEqual(lifecycle.state, .recoveryBlocked(.waitingForMatchingDevice))
        XCTAssertEqual(monitors.startAllCount, 0)
        XCTAssertEqual(monitors.startRouteOnlyCount, 1)
    }

    func testSuccessfulRecoveryStartsAllMonitorsOnce() async {
        let recovery = ControllableRecoveryRuntime(result: .restored)
        let monitors = MonitorSpy()
        let lifecycle = ApplicationLifecycleCoordinator(recovery: recovery, monitors: monitors)
        await lifecycle.start()
        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(monitors.startAllCount, 1)
    }
}
```

- [ ] **Step 8: Implement lifecycle states and recovery gate**

Define:

```swift
public enum AppLifecycleState: Equatable, Sendable {
    case recovering
    case ready
    case recoveryBlocked(SpeakerRecoveryOutcome)
}

public enum ShutdownOutcome: Equatable, Sendable {
    case restored
    case verifiedSilent
    case safetyUnknown
    case timedOut
}
```

The coordinator starts only route monitoring when recovery is blocked on a missing UID. It must not start lid/display timers, Chrome consumption, or a new protection transaction until recovery returns ready.

- [ ] **Step 9: Add route retry tests**

Create `ProtectionRouteRetryTests.swift` proving:

```swift
coordinator.setEnabled(true)
audio.defaultBuiltIn = nil
coordinator.receivePhysicalLid(closed: true)
XCTAssertEqual(coordinator.state, .unavailable)
audio.defaultBuiltIn = audio.deviceA
coordinator.receiveAudioRouteChanged()
XCTAssertEqual(coordinator.state, .protecting)
XCTAssertEqual(audio.writtenDeviceUIDs, ["built-in-a"])
```

Also cover built-in A -> external B -> protection end: runtime resolves and restores UID A from the device list, and no operation targets B.

- [ ] **Step 10: Wire AppViewModel to lifecycle, route, and recovery modules**

Inject one SystemAudioController, FileSpeakerRecoveryStore, and route monitor rather than constructing a controller inside each timer. Published state includes lifecycle/recovery status so UI can disable the guard while blocked. `start()` awaits recovery before starting lid/display/audio/Chrome work. `receiveAudioRouteChanged()` retries active protection and blocked recovery.

`shutdownAndRestore()` invalidates all timers, stops monitors, and returns the typed shutdown outcome. Do not swallow errors with `try?`; map them to the typed recovery/health state.

- [ ] **Step 11: Add termination decision tests**

Test an isolated termination coordinator rather than NSApplication itself:

```swift
@MainActor
func testRepeatedTerminationRequestsShareOneShutdown() async {
    let shutdown = ShutdownSpy(result: .restored)
    let coordinator = ApplicationTerminationCoordinator(shutdown: shutdown, timeout: .seconds(5))
    async let first = coordinator.requestTermination()
    async let second = coordinator.requestTermination()
    XCTAssertEqual(await [first, second], [.allow, .allow])
    XCTAssertEqual(shutdown.callCount, 1)
}
```

Cover restored/verifiedSilent -> allow, safetyUnknown -> cancel, and a controllable clock timeout -> cancel with `.timedOut`.

- [ ] **Step 12: Implement the AppKit termination handshake**

In `LidMuteAppDelegate`, implement `applicationShouldTerminate(_:)` to return `.terminateLater`, start or reuse the termination coordinator task, and call `NSApp.reply(toApplicationShouldTerminate:)` on MainActor. Remove the direct assumption that `applicationWillTerminate` can finish asynchronous restoration. The menu's Quit action may still call `terminate(nil)` because the delegate now gates it.

- [ ] **Step 13: Run focused, full, and packaging verification**

```bash
swift test --filter SpeakerRecoveryRuntimeTests
swift test --filter ProtectionCoordinatorJournalIntegrationTests
swift test --filter ApplicationLifecycleCoordinatorTests
swift test --filter ProtectionRouteRetryTests
swift test
zsh Scripts/make-app-bundle.sh
```

Expected: all commands exit 0. Tests cover every restore write/read/re-silence failure point; packaging produces the current local app bundle. Record physical route hot-swap and actual termination as manual gaps rather than claiming them tested.

- [ ] **Step 14: Commit the recovery lifecycle integration**

```bash
git add Sources Tests
git commit -m "feat: add fail-safe speaker recovery lifecycle" \
  -m "Constraint: Recovery must resolve the original built-in UID and journal every mutation" \
  -m "Rejected: Restore by cached AudioObjectID | IDs can become stale or be reused" \
  -m "Confidence: medium" \
  -m "Scope-risk: broad" \
  -m "Not-tested: Physical lid and audio-route hot-swap on a MacBook"
```

---

## Plan Completion Gate

Before the Chrome/observation plan integrates with `AppViewModel`, verify:

```bash
git status --short
swift test
node --test ChromeExtension/service-worker.test.mjs
zsh Scripts/run-smoke-check.sh
```

Expected: clean worktree; all XCTest and Node tests pass; smoke packaging exits 0. An independent reviewer must confirm that automatic media toggles are absent, physical/simulation/night sources cannot release one another, every audio mutation is journaled first, recovery only resolves the original built-in UID, and ordinary termination is cancelled for a safety-unknown outcome.
