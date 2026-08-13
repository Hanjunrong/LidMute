# LidMute Health and Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add typed, privacy-safe runtime health reporting and a deterministic Release packaging pipeline that produces either an explicitly local ad-hoc bundle or a fully signed and notarized Developer ID distribution bundle.

**Architecture:** Task 10 introduces small value types in `LidMuteCore`, keeps heartbeat file semantics behind one store, keeps Chrome registration inspection/repair behind one App-layer service, and routes diagnostics through a typed sink so callers cannot pass tab titles, URLs, or raw frames. Task 11 extracts safety-critical shell decisions into a sourceable packaging library, stages bundles inside `dist`, signs from the innermost executable outward, and makes Developer ID notarization a mandatory branch rather than an opportunistic enhancement.

**Tech Stack:** Swift 6, Swift Testing, Foundation, `OSLog.Logger`, zsh, Swift Package Manager, `codesign`, `security`, `xcrun notarytool`, `xcrun stapler`, `spctl`, PlistBuddy.

## Global Constraints

- This plan implements implementation-order Tasks 10 and 11 only; Tasks 1-9 from the protection, recovery, Chrome bridge, and bounded-storage plans must already be green.
- Depend on the protection plan's lifecycle/recovery health interface and the Chrome plan's accepted-event and observation-clear interfaces being stable; adapt those values into `AppHealthSnapshot` without changing their semantics or persistence contracts here.
- Minimum supported version remains macOS 15.
- Do not add third-party runtime dependencies.
- Do not restore automatic Chrome/protection-triggered global `playPause`; user-initiated media controls remain unchanged.
- Ordinary Chrome tabs continue to persist their complete URL, including query and fragment, under the already-confirmed privacy policy.
- Incognito tab title, URL, raw frame, and other tab-level evidence must never enter persistent files or diagnostics.
- Event persistence remains bounded to the latest 5,000 valid events by the preceding storage plan.
- The Native Host heartbeat interval is exactly 2 seconds and the App freshness TTL is exactly 6 seconds, both measured with `ProcessInfo.systemUptime`.
- A heartbeat with a negative uptime, an uptime greater than the current system uptime, malformed data, or age greater than 6 seconds is stale.
- `Logger` diagnostics accept typed, non-sensitive metadata only; no logging API introduced here may accept Chrome title, URL, raw payload, or arbitrary error text originating from a frame.
- `Scripts/make-app-bundle.sh` remains the only supported final App packaging entry point and defaults to a Release build.
- An unset `LIDMUTE_SIGNING_MODE` deterministically means `adhoc`; it must never inspect installed certificates to choose a mode.
- Ad-hoc output is visibly labeled “本地验收包，不可公开分发” and contains no `get-task-allow` entitlement.
- Developer ID mode requires both `LIDMUTE_DEVELOPER_IDENTITY` and `LIDMUTE_NOTARY_PROFILE`, uses Hardened Runtime, timestamping, notarization, and stapling, and never falls back to ad-hoc.
- Output replacement is allowed only for a canonical direct child of the repository `dist` directory whose basename ends in `.app`; reject `/`, the user home, repository root, nested paths, and paths outside `dist` before any removal or rename.
- Version values come only from `Config/Version.plist` keys `CFBundleShortVersionString` and `CFBundleVersion`.
- Do not redesign the Control Center Glass UI, window layout, or application icon.
- Run all repository builds through the project scripts described in `AGENTS.md`; do not use a direct build as proof of a packaged App.
- Implementation and approval review must happen in separate contexts; do not self-approve the implementation pass.

## Files and Interfaces

### Files created

- `Sources/LidMuteCore/HealthStatus.swift` — typed cross-layer health values and aggregate snapshot.
- `Sources/LidMuteCore/ChromeHostHeartbeat.swift` — heartbeat schema, atomic `0600` persistence, and monotonic freshness evaluation.
- `Sources/LidMuteApp/ChromeHostRegistration.swift` — manifest inspection and one-click path repair using the already registered extension ID.
- `Sources/LidMuteApp/LidMuteDiagnostics.swift` — typed diagnostic event/sink boundary and the `Logger` adapter.
- `Tests/LidMuteCoreTests/HealthStatusTests.swift` — health value and aggregate priority tests.
- `Tests/LidMuteCoreTests/ChromeHostHeartbeatTests.swift` — 2-second/6-second uptime and persistence tests.
- `Tests/LidMuteAppTests/ChromeHostRegistrationTests.swift` — moved-bundle manifest detection and repair tests.
- `Tests/LidMuteAppTests/LidMuteDiagnosticsTests.swift` — privacy-safe diagnostic projection tests.
- `Tests/LidMuteAppTests/AppViewModelHealthTests.swift` — heartbeat expiry, health projection, and manifest repair presentation tests.
- `Scripts/lib/release-packaging.zsh` — path validation, version loading, signing, verification, notarization, and atomic installation helpers.
- `Scripts/test-release-packaging.sh` — credential-free packaging policy tests and optional credentialed Developer ID assertions.
- `Config/Version.plist` — single controlled source for marketing/build versions.
- `Config/LidMuteRelease.entitlements` — release entitlements shared by ad-hoc and Developer ID builds, explicitly without `get-task-allow`.

### Files modified

- `Package.swift` — expose `LidMuteCoreTests` and `LidMuteAppTests` to `swift test`; make the Native Host consume shared heartbeat types if the prior Chrome task has not already added that dependency.
- `Sources/LidMuteNativeHost/main.swift` — own a heartbeat writer for the lifetime of an authenticated native connection and clean it on normal exit.
- `Sources/LidMuteApp/AppViewModel.swift` — publish one typed health snapshot, inspect heartbeat freshness, expose manifest repair, and emit typed diagnostics.
- `Sources/LidMuteApp/ContentView.swift` — distinguish no-data from unavailable/degraded states and add the manifest path repair action without changing the visual system.
- `Scripts/make-app-bundle.sh` — default to Release, stage safely, load controlled versions, and invoke explicit signing/notarization branches.
- `Scripts/run-smoke-check.sh` — assert Release provenance, controlled versions, safe entitlements, local labeling, strict signatures, and packaging policy tests.
- `README.md` — document health semantics, full ordinary-tab URL retention, incognito zero-persistence, and both packaging modes.
- `README.zh-CN.md` — mirror the user-facing health/privacy/release guidance.

### Stable interfaces produced by this plan

```swift
public enum CoreAudioHealth: Equatable, Sendable {
    case healthyNoActiveOutput
    case healthy(activeOutputCount: Int)
    case queryFailed
}

public enum LidMonitorHealth: Equatable, Sendable {
    case healthy
    case unavailable
    case readFailed
}

public enum ChromeBridgeHealth: Equatable, Sendable {
    case notRegistered
    case waitingForConnection
    case connected(sessionToken: UUID, pid: Int32)
    case recentlyAccepted(sessionToken: UUID, pid: Int32)
    case manifestPathMismatch(expected: String, registered: String)
    case degraded
}

public enum LocalStorageHealth: Equatable, Sendable {
    case healthy
    case partiallyCorrupt
    case permissionFailed
    case capacityFailed
    case ioFailed
}

public enum SpeakerRecoveryHealth: Equatable, Sendable {
    case healthy
    case waitingForMatchingDevice
    case corruptSnapshot
    case unsupportedSnapshot
    case failedButVerifiedSilent
    case failedSafetyUnknown
}

public struct AppHealthSnapshot: Equatable, Sendable {
    public let coreAudio: CoreAudioHealth
    public let lidMonitor: LidMonitorHealth
    public let chrome: ChromeBridgeHealth
    public let storage: LocalStorageHealth
    public let recovery: SpeakerRecoveryHealth
    public var highestPriority: HealthPriority { get }
}

public struct ChromeHostHeartbeat: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let version: Int
    public let sessionToken: UUID
    public let pid: Int32
    public let uptime: TimeInterval
}

public enum HeartbeatFreshness: Equatable, Sendable {
    case fresh(sessionToken: UUID, pid: Int32)
    case stale
    case malformed
}

public protocol ChromeHostHeartbeatPersisting: Sendable {
    func write(_ heartbeat: ChromeHostHeartbeat) throws
    func readFreshness(nowUptime: TimeInterval, ttl: TimeInterval) -> HeartbeatFreshness
    func remove() throws
}

@MainActor
protocol ChromeHostRegistering {
    func inspect(expectedHostPath: URL) -> ChromeManifestInspection
    func repair(expectedHostPath: URL) throws
}

enum LidMuteDiagnosticEvent: Equatable, Sendable {
    case coreAudioQueryFailed
    case lidMonitorUnavailable
    case lidMonitorReadFailed
    case chromeHeartbeatStale
    case chromeManifestPathMismatch
    case chromeManifestRepaired
    case chromeBridgeDegraded
    case storagePartiallyCorrupt
    case storagePermissionFailed
    case storageCapacityFailed
    case recoveryWaitingForMatchingDevice
    case recoveryFailedButVerifiedSilent
    case recoveryFailedSafetyUnknown
}

protocol LidMuteDiagnosticSinking: Sendable {
    func emit(_ event: LidMuteDiagnosticEvent)
}
```

---

### Task 10: Typed Runtime Health, Heartbeat, Manifest Repair, and Privacy-Safe Diagnostics

**Files:**
- Create: `Sources/LidMuteCore/HealthStatus.swift`
- Create: `Sources/LidMuteCore/ChromeHostHeartbeat.swift`
- Create: `Sources/LidMuteApp/ChromeHostRegistration.swift`
- Create: `Sources/LidMuteApp/LidMuteDiagnostics.swift`
- Create: `Tests/LidMuteCoreTests/HealthStatusTests.swift`
- Create: `Tests/LidMuteCoreTests/ChromeHostHeartbeatTests.swift`
- Create: `Tests/LidMuteAppTests/ChromeHostRegistrationTests.swift`
- Create: `Tests/LidMuteAppTests/LidMuteDiagnosticsTests.swift`
- Create: `Tests/LidMuteAppTests/AppViewModelHealthTests.swift`
- Modify: `Package.swift`
- Modify: `Sources/LidMuteNativeHost/main.swift`
- Modify: `Sources/LidMuteApp/SystemLidMonitor.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Modify: `Sources/LidMuteApp/ContentView.swift`

**Interfaces:**
- Consumes: protection Task 6's `SpeakerRecoveryOutcome` (`noPendingRecovery`, `restored`, `waitingForMatchingDevice`, `corruptSnapshot`, `unsupportedSnapshot`, `failedButVerifiedSilent`, `failedSafetyUnknown`); Chrome Task 9's exact `ObservationStorageHealth` (`healthy`, `corruptRecord(line:)`, `permissionFailure`, `capacityFailure`, `ioFailure(String)`), accepted-event callback, bridge degradation callback, and observation-clear result. Do not make those modules depend on App presentation types.
- Produces: all health, heartbeat, registration, and diagnostic interfaces listed under “Stable interfaces produced by this plan”; `AppViewModel.health: AppHealthSnapshot`; `AppViewModel.canRepairChromeManifest: Bool`; `AppViewModel.repairChromeManifest()`.

- [ ] **Step 1: Add failing typed-health tests**

Create `Tests/LidMuteCoreTests/HealthStatusTests.swift` with explicit no-data/error separation and priority ordering:

```swift
import Testing
@testable import LidMuteCore

@Test func noActiveAudioIsHealthyRatherThanAnError() {
    #expect(CoreAudioHealth.healthyNoActiveOutput != .queryFailed)
}

@Test func unknownRecoverySafetyHasHighestPriority() {
    let snapshot = AppHealthSnapshot(
        coreAudio: .healthyNoActiveOutput,
        lidMonitor: .healthy,
        chrome: .waitingForConnection,
        storage: .healthy,
        recovery: .failedSafetyUnknown
    )
    #expect(snapshot.highestPriority == .critical)
    #expect(snapshot.blocksNormalTermination)
}

@Test func verifiedSilentFailureWarnsButDoesNotBlockTermination() {
    let snapshot = AppHealthSnapshot(
        coreAudio: .healthy(activeOutputCount: 1),
        lidMonitor: .healthy,
        chrome: .degraded,
        storage: .partiallyCorrupt,
        recovery: .failedButVerifiedSilent
    )
    #expect(snapshot.highestPriority == .warning)
    #expect(!snapshot.blocksNormalTermination)
}
```

- [ ] **Step 2: Run the typed-health tests and verify RED**

Run: `swift test --filter HealthStatusTests`

Expected: FAIL at compile time because `CoreAudioHealth`, `AppHealthSnapshot`, and `HealthPriority` do not exist.

- [ ] **Step 3: Implement the typed health model**

Create `Sources/LidMuteCore/HealthStatus.swift` with the exact enum cases in the stable interface, plus:

```swift
public enum HealthPriority: Int, Comparable, Sendable {
    case normal = 0
    case notice = 1
    case warning = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public extension AppHealthSnapshot {
    var highestPriority: HealthPriority {
        if recovery == .failedSafetyUnknown { return .critical }
        if recovery == .failedButVerifiedSilent || recovery == .corruptSnapshot ||
            recovery == .unsupportedSnapshot || storage != .healthy ||
            coreAudio == .queryFailed || lidMonitor != .healthy || chrome == .degraded {
            return .warning
        }
        if recovery == .waitingForMatchingDevice || chrome == .waitingForConnection ||
            chrome == .notRegistered {
            return .notice
        }
        return .normal
    }

    var blocksNormalTermination: Bool { recovery == .failedSafetyUnknown }
}
```

Use explicit `switch` statements where associated-value enum equality makes the abbreviated comparisons invalid; preserve exactly the priority policy asserted above.

- [ ] **Step 4: Run the typed-health tests and verify GREEN**

Run: `swift test --filter HealthStatusTests`

Expected: PASS with 3 tests and no warning that “no active output” was projected as a failure.

- [ ] **Step 5: Add failing heartbeat schema, TTL, permissions, and cleanup tests**

Create `Tests/LidMuteCoreTests/ChromeHostHeartbeatTests.swift`:

```swift
import Foundation
import Testing
@testable import LidMuteCore

@Test func heartbeatIsFreshThroughSixSecondsOnly() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let url = root.appending(path: "chrome-host-heartbeat.json")
    let store = FileChromeHostHeartbeatStore(url: url)
    let token = UUID()
    try store.write(.init(version: 1, sessionToken: token, pid: 4312, uptime: 100))
    #expect(store.readFreshness(nowUptime: 106, ttl: 6) == .fresh(sessionToken: token, pid: 4312))
    #expect(store.readFreshness(nowUptime: 106.001, ttl: 6) == .stale)
}

@Test(arguments: [-1.0, 101.0])
func impossibleHeartbeatUptimeIsStale(_ heartbeatUptime: TimeInterval) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = FileChromeHostHeartbeatStore(url: root.appending(path: "heartbeat.json"))
    try store.write(.init(version: 1, sessionToken: UUID(), pid: 7, uptime: heartbeatUptime))
    #expect(store.readFreshness(nowUptime: 100, ttl: 6) == .stale)
}

@Test func heartbeatFileIsPrivateAndRemovalIsIdempotent() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let url = root.appending(path: "heartbeat.json")
    let store = FileChromeHostHeartbeatStore(url: url)
    try store.write(.init(version: 1, sessionToken: UUID(), pid: 9, uptime: 5))
    let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
    #expect(mode.intValue == 0o600)
    try store.remove()
    try store.remove()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
```

- [ ] **Step 6: Run heartbeat tests and verify RED**

Run: `swift test --filter ChromeHostHeartbeatTests`

Expected: FAIL at compile time because `ChromeHostHeartbeat`, `HeartbeatFreshness`, and `FileChromeHostHeartbeatStore` do not exist.

- [ ] **Step 7: Implement atomic heartbeat persistence and monotonic freshness**

Create `Sources/LidMuteCore/ChromeHostHeartbeat.swift`. Encode to a sibling temporary file, set it to `0600`, replace the target atomically, and keep the parent directory at `0700`. Decode failures and unsupported schema return `.malformed`; only a nonnegative heartbeat uptime satisfying `heartbeat.uptime <= nowUptime` and `nowUptime - heartbeat.uptime <= ttl` returns `.fresh`:

```swift
public func readFreshness(nowUptime: TimeInterval, ttl: TimeInterval = 6) -> HeartbeatFreshness {
    guard let data = try? Data(contentsOf: url),
          let heartbeat = try? JSONDecoder().decode(ChromeHostHeartbeat.self, from: data),
          heartbeat.version == ChromeHostHeartbeat.schemaVersion else { return .malformed }
    guard heartbeat.uptime >= 0,
          heartbeat.uptime <= nowUptime,
          nowUptime - heartbeat.uptime <= ttl else { return .stale }
    return .fresh(sessionToken: heartbeat.sessionToken, pid: heartbeat.pid)
}
```

Do not put wall-clock dates into freshness decisions.

- [ ] **Step 8: Run heartbeat tests and verify GREEN**

Run: `swift test --filter ChromeHostHeartbeatTests`

Expected: PASS for the exact 6-second boundary, stale future/negative uptime, `0600`, and repeated removal.

- [ ] **Step 9: Add a failing Native Host source-contract test for the 2-second writer lifecycle**

Extend `Scripts/run-smoke-check.sh` with:

```zsh
grep -Fq 'heartbeatInterval: 2' Sources/LidMuteNativeHost/main.swift
grep -Fq 'defer { heartbeatWriter.stopAndRemove() }' Sources/LidMuteNativeHost/main.swift
```

- [ ] **Step 10: Run the smoke check and verify RED at the heartbeat contract**

Run: `zsh Scripts/run-smoke-check.sh`

Expected: FAIL because `main.swift` does not yet construct a 2-second heartbeat writer or remove its file on normal exit.

- [ ] **Step 11: Start and clean up the Native Host heartbeat writer**

Make `LidMuteNativeHost` depend on `LidMuteCore` in `Package.swift` if the Chrome hardening task has not already done so. In `main.swift`, after origin authentication and before reading stdin, construct one random token for this Host process and write immediately, then every 2 seconds:

```swift
let heartbeatStore = FileChromeHostHeartbeatStore(
    url: appDirectory.appending(path: "chrome-host-heartbeat.json")
)
let heartbeatWriter = ChromeHostHeartbeatWriter(
    store: heartbeatStore,
    sessionToken: UUID(),
    pid: Int32(ProcessInfo.processInfo.processIdentifier),
    heartbeatInterval: 2,
    uptime: { ProcessInfo.processInfo.systemUptime }
)
try heartbeatWriter.start()
defer { heartbeatWriter.stopAndRemove() }
```

Implement `ChromeHostHeartbeatWriter` with a serial `DispatchQueue` and `DispatchSourceTimer`; `start()` must synchronously persist the first heartbeat before returning. `stopAndRemove()` cancels the timer, synchronizes with an in-flight write, and idempotently removes only this session's heartbeat: read the file first and remove it only when `sessionToken` still matches, so an older Host instance cannot erase a newer instance's heartbeat.

- [ ] **Step 12: Run heartbeat unit tests and smoke source contract**

Run: `swift test --filter ChromeHostHeartbeatTests && zsh Scripts/run-smoke-check.sh`

Expected: PASS through heartbeat tests and the new source-contract checks; any later unrelated packaging RED is handled by Task 11.

- [ ] **Step 13: Add failing manifest mismatch and repair tests**

Create `Tests/LidMuteAppTests/ChromeHostRegistrationTests.swift` using a temporary manifest/origin directory and an injected `FileManager` root:

```swift
import Foundation
import Testing
@testable import LidMuteApp

@MainActor @Test func movedBundleIsDetectedAndRepairPreservesRegisteredOrigin() throws {
    let fixture = try ChromeRegistrationFixture(
        registeredHostPath: "/Users/test/Downloads/LidMute.app/Contents/MacOS/LidMuteNativeHost",
        registeredOrigin: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"
    )
    let service = ChromeHostRegistration(
        manifestURL: fixture.manifestURL,
        originURL: fixture.originURL
    )
    let expected = URL(filePath: "/Applications/LidMute.app/Contents/MacOS/LidMuteNativeHost")
    #expect(service.inspect(expectedHostPath: expected) == .pathMismatch(
        expected: expected.path,
        registered: "/Users/test/Downloads/LidMute.app/Contents/MacOS/LidMuteNativeHost"
    ))
    try service.repair(expectedHostPath: expected)
    let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifestURL)) as? [String: Any]
    #expect(repaired?["path"] as? String == expected.path)
    #expect(repaired?["allowed_origins"] as? [String] == ["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"])
}

@MainActor @Test func repairRejectsMissingOrInvalidRegisteredExtensionID() throws {
    let fixture = try ChromeRegistrationFixture(registeredHostPath: "/old/host", registeredOrigin: "chrome-extension://bad/")
    let service = ChromeHostRegistration(manifestURL: fixture.manifestURL, originURL: fixture.originURL)
    #expect(throws: ChromeHostRegistrationError.invalidRegisteredExtensionID) {
        try service.repair(expectedHostPath: URL(filePath: "/Applications/LidMute.app/Contents/MacOS/LidMuteNativeHost"))
    }
}
```

The fixture writes real JSON and origin files and removes its temporary directory in `deinit`; do not mock JSON parsing.

- [ ] **Step 14: Run manifest tests and verify RED**

Run: `swift test --filter ChromeHostRegistrationTests`

Expected: FAIL at compile time because `ChromeHostRegistration`, `ChromeManifestInspection`, and `ChromeHostRegistrationError` do not exist.

- [ ] **Step 15: Implement registration inspection and safe repair**

Create `Sources/LidMuteApp/ChromeHostRegistration.swift` with:

```swift
enum ChromeManifestInspection: Equatable {
    case notRegistered
    case current
    case pathMismatch(expected: String, registered: String)
    case malformed
}

enum ChromeHostRegistrationError: Error, Equatable {
    case invalidRegisteredExtensionID
    case expectedHostNotExecutable
    case malformedManifest
}
```

`inspect(expectedHostPath:)` parses the manifest JSON and compares standardized file URLs. `repair(expectedHostPath:)` requires `FileManager.isExecutableFile`, extracts the existing origin, validates the extension ID against `^[a-p]{32}$`, serializes JSON with `JSONSerialization`, atomically replaces the manifest, and sets `0600`. Preserve `name`, `description`, `type`, and the one legal `allowed_origins` value; replace only `path`. Never accept a fresh ID from editable UI text for this repair operation.

- [ ] **Step 16: Run manifest tests and verify GREEN**

Run: `swift test --filter ChromeHostRegistrationTests`

Expected: PASS for moved-path detection, legal-origin preservation, and invalid-ID rejection.

- [ ] **Step 17: Add failing privacy-safe diagnostics tests**

Create `Tests/LidMuteAppTests/LidMuteDiagnosticsTests.swift`:

```swift
import Testing
@testable import LidMuteApp

private final class RecordingDiagnosticSink: LidMuteDiagnosticSinking, @unchecked Sendable {
    private(set) var events: [LidMuteDiagnosticEvent] = []
    func emit(_ event: LidMuteDiagnosticEvent) { events.append(event) }
}

@Test func diagnosticEventsContainNoArbitraryStringPayload() {
    let mirror = Mirror(reflecting: LidMuteDiagnosticEvent.chromeBridgeDegraded)
    #expect(mirror.children.isEmpty)
    #expect(!String(reflecting: LidMuteDiagnosticEvent.self).contains("ChromeTabEvidence"))
}

@Test func healthTransitionsEmitTypedEventsOnly() {
    let sink = RecordingDiagnosticSink()
    sink.emit(.chromeHeartbeatStale)
    sink.emit(.recoveryFailedSafetyUnknown)
    #expect(sink.events == [.chromeHeartbeatStale, .recoveryFailedSafetyUnknown])
}
```

- [ ] **Step 18: Run diagnostics tests and verify RED**

Run: `swift test --filter LidMuteDiagnosticsTests`

Expected: FAIL at compile time because the typed event and sink do not exist.

- [ ] **Step 19: Implement the typed Logger adapter**

Create `Sources/LidMuteApp/LidMuteDiagnostics.swift`. `LoggerDiagnosticSink.emit(_:)` switches over the closed enum and logs fixed messages plus only non-sensitive fixed reason codes:

```swift
import OSLog

struct LoggerDiagnosticSink: LidMuteDiagnosticSinking {
    private let logger = Logger(subsystem: "local.lidmute.app", category: "health")

    func emit(_ event: LidMuteDiagnosticEvent) {
        switch event {
        case .chromeHeartbeatStale:
            logger.notice("Chrome heartbeat stale")
        case .coreAudioQueryFailed:
            logger.error("CoreAudio query failed")
        case .lidMonitorUnavailable:
            logger.error("Lid monitor unavailable")
        case .lidMonitorReadFailed:
            logger.error("Lid monitor read failed")
        case .chromeManifestPathMismatch:
            logger.notice("Chrome manifest path mismatch")
        case .chromeManifestRepaired:
            logger.notice("Chrome manifest repaired")
        case .chromeBridgeDegraded:
            logger.error("Chrome bridge degraded")
        case .storagePartiallyCorrupt:
            logger.error("Observation storage partially corrupt")
        case .storagePermissionFailed:
            logger.error("Observation storage permission failed")
        case .storageCapacityFailed:
            logger.error("Observation storage capacity failed")
        case .recoveryWaitingForMatchingDevice:
            logger.notice("Speaker recovery waiting for matching device")
        case .recoveryFailedButVerifiedSilent:
            logger.error("Speaker recovery failed with silence verified")
        case .recoveryFailedSafetyUnknown:
            logger.fault("Speaker recovery safety unknown")
        }
    }
}
```

Do not add overloads taking `String`, `Error`, `ChromeTabEvidence`, or raw `Data`. Existing Chrome decode/ignore/reject paths may log only the typed disposition/reason code supplied by the Chrome plan, never the payload.

- [ ] **Step 20: Run diagnostics tests and verify GREEN**

Run: `swift test --filter LidMuteDiagnosticsTests`

Expected: PASS; the only diagnostic API surface accepts a closed enum without arbitrary associated strings.

- [ ] **Step 21: Add failing App health/heartbeat/repair presentation tests**

Extend `Tests/LidMuteAppTests/AppViewModelHealthTests.swift` (create it if the lifecycle plan has not already done so) with injected heartbeat store, registration service, monotonic uptime, and diagnostic sink:

```swift
@MainActor @Test func staleHeartbeatDoesNotReportChromeConnected() {
    let fixture = AppHealthFixture(heartbeat: .init(version: 1, sessionToken: UUID(), pid: 8, uptime: 10), nowUptime: 16.001)
    let model = fixture.makeViewModel()
    model.refreshHealth()
    #expect(model.health.chrome == .waitingForConnection)
    #expect(fixture.diagnostics.events == [.chromeHeartbeatStale])
}

@MainActor @Test func movedManifestOffersRepairAndRepairClearsMismatch() throws {
    let fixture = AppHealthFixture(manifestPath: "/old/LidMuteNativeHost", expectedHostPath: "/Applications/LidMute.app/Contents/MacOS/LidMuteNativeHost")
    let model = fixture.makeViewModel()
    model.refreshHealth()
    #expect(model.canRepairChromeManifest)
    model.repairChromeManifest()
    #expect(!model.canRepairChromeManifest)
    #expect(fixture.registration.repairCalls == 1)
}

@MainActor @Test func coreAudioFailureIsNotProjectedAsNoOutput() {
    let fixture = AppHealthFixture(audioPoll: .failure(.queryFailed))
    let model = fixture.makeViewModel()
    model.pollAudioProcesses()
    #expect(model.health.coreAudio == .queryFailed)
    #expect(fixture.diagnostics.events.contains(.coreAudioQueryFailed))
}

@MainActor @Test func lidUnavailableAndReadFailureHaveDistinctHealth() {
    let unavailable = AppHealthFixture(lidResult: .unavailable).makeViewModel()
    unavailable.refreshHealth()
    #expect(unavailable.health.lidMonitor == .unavailable)
    let failed = AppHealthFixture(lidResult: .readFailed).makeViewModel()
    failed.refreshHealth()
    #expect(failed.health.lidMonitor == .readFailed)
}

@MainActor @Test(arguments: [
    (ObservationStorageHealth.healthy, LocalStorageHealth.healthy),
    (.corruptRecord(line: 17), .partiallyCorrupt),
    (.permissionFailure, .permissionFailed),
    (.capacityFailure, .capacityFailed),
    (.ioFailure("fixed-test-reason"), .ioFailed),
])
func everyStorageOutcomeMapsToHealth(input: ObservationStorageHealth, expected: LocalStorageHealth) {
    #expect(AppHealthMapper.storage(input) == expected)
}

@MainActor @Test(arguments: [
    (SpeakerRecoveryOutcome.noPendingRecovery, SpeakerRecoveryHealth.healthy),
    (.restored, .healthy),
    (.waitingForMatchingDevice, .waitingForMatchingDevice),
    (.corruptSnapshot, .corruptSnapshot),
    (.unsupportedSnapshot(99), .unsupportedSnapshot),
    (.failedButVerifiedSilent, .failedButVerifiedSilent),
    (.failedSafetyUnknown, .failedSafetyUnknown),
])
func everyRecoveryOutcomeMapsToHealth(input: SpeakerRecoveryOutcome, expected: SpeakerRecoveryHealth) {
    #expect(AppHealthMapper.recovery(input) == expected)
}
```

- [ ] **Step 22: Run App health tests and verify RED**

Run: `swift test --filter AppViewModelHealthTests`

Expected: FAIL because the ViewModel does not inject heartbeat/registration/diagnostics or publish typed health.

- [ ] **Step 23: Integrate typed health into AppViewModel and ContentView**

Inject `ChromeHostHeartbeatPersisting`, `ChromeHostRegistering`, `LidMuteDiagnosticSinking`, typed audio-poll results, typed lid-monitor results, storage health, recovery outcome, and `uptime: () -> TimeInterval` into the ViewModel with production defaults. Replace `kill(pid, 0)` connection inference with `readFreshness(nowUptime: uptime(), ttl: 6)`. Preserve `.recentlyAccepted` only when the preceding Chrome plan reports a durable accepted event in the current fresh heartbeat session.

Change `SystemLidMonitor`'s callback to report `LidMonitorResult.state(Bool)`, `.unavailable`, or `.readFailed` instead of silently returning from `poll()`. Change the audio polling adapter to return `Result<[AudioProcess], AudioQueryFailure>`; on failure keep the last known process snapshot and project `.queryFailed`, rather than replacing it with `[]`.

Add exact total mappers:

```swift
enum AppHealthMapper {
    static func storage(_ value: ObservationStorageHealth) -> LocalStorageHealth {
        switch value {
        case .healthy: return .healthy
        case .corruptRecord: return .partiallyCorrupt
        case .permissionFailure: return .permissionFailed
        case .capacityFailure: return .capacityFailed
        case .ioFailure: return .ioFailed
        }
    }

    static func recovery(_ value: SpeakerRecoveryOutcome) -> SpeakerRecoveryHealth {
        switch value {
        case .noPendingRecovery, .restored: return .healthy
        case .waitingForMatchingDevice: return .waitingForMatchingDevice
        case .corruptSnapshot: return .corruptSnapshot
        case .unsupportedSnapshot: return .unsupportedSnapshot
        case .failedButVerifiedSilent: return .failedButVerifiedSilent
        case .failedSafetyUnknown: return .failedSafetyUnknown
        }
    }
}
```

Map prior-plan health values without swallowing failures:

```swift
@Published private(set) var health = AppHealthSnapshot(
    coreAudio: .healthyNoActiveOutput,
    lidMonitor: .healthy,
    chrome: .waitingForConnection,
    storage: .healthy,
    recovery: .healthy
)
@Published private(set) var canRepairChromeManifest = false
```

In `ContentView`, render separate fixed copy for `.healthyNoActiveOutput` (“当前没有活动音频”) and `.queryFailed` (“无法查询 CoreAudio，请检查系统状态”). For `.manifestPathMismatch`, show the old/new paths and a “修复 Chrome 通信路径” button wired to `repairChromeManifest()`. For `.failedSafetyUnknown`, use the existing highest-priority danger styling and state that normal quit is blocked; do not claim the speaker is silent. Keep all layout metrics and card modifiers unchanged.

- [ ] **Step 24: Run Task 10 focused and full automated tests**

Run: `swift test --filter HealthStatusTests && swift test --filter ChromeHostHeartbeatTests && swift test --filter ChromeHostRegistrationTests && swift test --filter LidMuteDiagnosticsTests && swift test --filter AppViewModelHealthTests && swift test`

Expected: every command exits 0; stale/malformed heartbeat never maps to connected, repair preserves the registered legal origin, no-data differs from failure, and critical recovery safety blocks normal termination.

- [ ] **Step 25: Commit Task 10**

```bash
git add Package.swift Sources/LidMuteCore/HealthStatus.swift Sources/LidMuteCore/ChromeHostHeartbeat.swift Sources/LidMuteNativeHost/main.swift Sources/LidMuteApp/SystemLidMonitor.swift Sources/LidMuteApp/ChromeHostRegistration.swift Sources/LidMuteApp/LidMuteDiagnostics.swift Sources/LidMuteApp/AppViewModel.swift Sources/LidMuteApp/ContentView.swift Tests/LidMuteCoreTests/HealthStatusTests.swift Tests/LidMuteCoreTests/ChromeHostHeartbeatTests.swift Tests/LidMuteAppTests/ChromeHostRegistrationTests.swift Tests/LidMuteAppTests/LidMuteDiagnosticsTests.swift Tests/LidMuteAppTests/AppViewModelHealthTests.swift Scripts/run-smoke-check.sh
git commit -m "feat: add typed runtime health and heartbeat"
```

### Task 11: Deterministic Release Packaging, Signing, Notarization, and Final Acceptance

**Files:**
- Create: `Scripts/lib/release-packaging.zsh`
- Create: `Scripts/test-release-packaging.sh`
- Create: `Config/Version.plist`
- Create: `Config/LidMuteRelease.entitlements`
- Modify: `Scripts/make-app-bundle.sh`
- Modify: `Scripts/run-smoke-check.sh`
- Modify: `README.md`
- Modify: `README.zh-CN.md`

**Interfaces:**
- Consumes: Task 10's `chrome-host-heartbeat.json` behavior and manifest repair UI; the stable protection/Chrome/storage interfaces declared in Global Constraints; existing app, Native Host, icon, and bundled extension products.
- Produces: `validate_output_path <repo-root> <candidate>` printing a canonical safe target or returning 64; `read_version_value <version-plist> <key>`; `sign_adhoc_bundle <repo-root> <app>`; `sign_developer_id_bundle <repo-root> <app> <identity>`; `notarize_and_staple <app> <profile> <staging-dir>`; `verify_adhoc_bundle <app>`; `verify_developer_id_bundle <app>`; and a packaged App whose `Contents/Resources/BuildChannel.txt` is exactly `local-adhoc\n` or `developer-id-notarized\n`.

- [ ] **Step 1: Add failing safe-output-path policy tests**

Create `Scripts/test-release-packaging.sh` with a temporary fake repository whose `dist` directory is on the same filesystem:

```zsh
#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
source "$root/Scripts/lib/release-packaging.zsh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/lidmute-package-policy.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/repo/dist" "$fixture/repo/nested"

safe="$(validate_output_path "$fixture/repo" "$fixture/repo/dist/LidMute.app")"
[[ "$safe" == "$fixture/repo/dist/LidMute.app" ]]

for unsafe in "/" "$HOME" "$fixture/repo" "$fixture/repo/dist" \
  "$fixture/repo/LidMute.app" "$fixture/repo/dist/nested/LidMute.app" \
  "$fixture/repo/dist/not-an-app"; do
  if validate_output_path "$fixture/repo" "$unsafe" >/dev/null 2>&1; then
    print -u2 "unexpected safe path: $unsafe"
    exit 1
  fi
done
print "PASS release packaging path policy"
```

- [ ] **Step 2: Run packaging policy test and verify RED**

Run: `zsh Scripts/test-release-packaging.sh`

Expected: FAIL because `Scripts/lib/release-packaging.zsh` does not exist.

- [ ] **Step 3: Implement canonical direct-child path validation**

Create `Scripts/lib/release-packaging.zsh`. `validate_output_path` must canonicalize an existing parent directory with `cd -P`, derive the candidate basename without evaluating it as code, reject symlink parents, require parent equality with canonical `$root/dist`, require `*.app`, and explicitly reject `/`, canonical `$HOME`, and canonical repo root:

```zsh
validate_output_path() {
  local repo_root="$1" candidate="$2"
  local canonical_root="$(cd -P -- "$repo_root" && pwd)" || return 64
  local dist="$canonical_root/dist"
  mkdir -p -- "$dist" || return 64
  local canonical_dist="$(cd -P -- "$dist" && pwd)" || return 64
  local parent="${candidate:h}" base="${candidate:t}"
  local canonical_parent="$(cd -P -- "$parent" 2>/dev/null && pwd)" || return 64
  [[ "$canonical_parent" == "$canonical_dist" ]] || return 64
  [[ "$base" == *.app && "$base" != ".app" ]] || return 64
  local resolved="$canonical_parent/$base"
  [[ "$resolved" != "/" && "$resolved" != "$HOME" && "$resolved" != "$canonical_root" ]] || return 64
  print -r -- "$resolved"
}
```

All deletion/backup helpers in this library must call `validate_output_path` first and operate only on the returned path or on a `mktemp -d "$canonical_dist/.lidmute-stage.XXXXXX"` / `.lidmute-backup.<UUID>` direct child.

- [ ] **Step 4: Run path policy tests and verify GREEN**

Run: `zsh Scripts/test-release-packaging.sh`

Expected: print `PASS release packaging path policy` and exit 0.

- [ ] **Step 5: Add controlled version and release-entitlement fixtures plus failing assertions**

Create `Config/Version.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
```

Create `Config/LidMuteRelease.entitlements` as an empty entitlement dictionary:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
```

Append to `Scripts/test-release-packaging.sh`:

```zsh
[[ "$(read_version_value "$root/Config/Version.plist" CFBundleShortVersionString)" == "0.1.0" ]]
[[ "$(read_version_value "$root/Config/Version.plist" CFBundleVersion)" == "1" ]]
! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$root/Config/LidMuteRelease.entitlements" >/dev/null 2>&1
print "PASS controlled version and release entitlements"
```

- [ ] **Step 6: Run version policy test and verify RED**

Run: `zsh Scripts/test-release-packaging.sh`

Expected: FAIL with `command not found: read_version_value` after the path-policy PASS.

- [ ] **Step 7: Implement strict version loading**

Add to `Scripts/lib/release-packaging.zsh`:

```zsh
read_version_value() {
  local plist="$1" key="$2" value
  [[ "$key" == "CFBundleShortVersionString" || "$key" == "CFBundleVersion" ]] || return 65
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || return 65
  if [[ "$key" == "CFBundleShortVersionString" ]]; then
    [[ "$value" == <->.<->.<-> ]] || return 65
  else
    [[ "$value" == <-> && "$value" -ge 1 ]] || return 65
  fi
  print -r -- "$value"
}
```

- [ ] **Step 8: Run version and entitlement policy tests and verify GREEN**

Run: `zsh Scripts/test-release-packaging.sh`

Expected: both `PASS release packaging path policy` and `PASS controlled version and release entitlements`.

- [ ] **Step 9: Add failing deterministic-mode and credential-gate tests**

Append credential-free subprocess assertions to `Scripts/test-release-packaging.sh`:

```zsh
mode="$(resolve_signing_mode "")"
[[ "$mode" == "adhoc" ]]
[[ "$(resolve_signing_mode adhoc)" == "adhoc" ]]
[[ "$(resolve_signing_mode developer-id)" == "developer-id" ]]
if resolve_signing_mode automatic >/dev/null 2>&1; then exit 1; fi
if validate_developer_id_inputs "" "profile" >/dev/null 2>&1; then exit 1; fi
if validate_developer_id_inputs "Developer ID Application: Example (TEAMID)" "" >/dev/null 2>&1; then exit 1; fi
print "PASS deterministic signing mode and credential gates"
```

- [ ] **Step 10: Run mode policy test and verify RED**

Run: `zsh Scripts/test-release-packaging.sh`

Expected: FAIL with `command not found: resolve_signing_mode`.

- [ ] **Step 11: Implement explicit signing-mode selection and fail-closed Developer ID inputs**

Add functions that accept only `adhoc` and `developer-id`. `validate_developer_id_inputs` requires nonempty identity/profile, requires the identity string to begin with `Developer ID Application: `, and verifies it exactly with `security find-identity -v -p codesigning`; do not select the first installed identity and do not catch this failure to run ad-hoc signing.

```zsh
resolve_signing_mode() {
  case "${1:-adhoc}" in
    adhoc|developer-id) print -r -- "${1:-adhoc}" ;;
    *) print -u2 "LIDMUTE_SIGNING_MODE must be adhoc or developer-id"; return 64 ;;
  esac
}
```

Allow `validate_developer_id_inputs` to skip `security` lookup only when `LIDMUTE_TEST_SKIP_IDENTITY_LOOKUP=1`, used solely by credential-free function tests; the production script must never set it.

- [ ] **Step 12: Run mode tests and verify GREEN**

Run: `LIDMUTE_TEST_SKIP_IDENTITY_LOOKUP=1 zsh Scripts/test-release-packaging.sh`

Expected: all three PASS lines and no certificate-dependent branch.

- [ ] **Step 13: Add failing source-contract tests for Release provenance, staging, and inward-out signing**

Append to `Scripts/test-release-packaging.sh`:

```zsh
grep -Fq -- '--configuration release' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'mktemp -d "$dist/.lidmute-stage.XXXXXX"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'sign_adhoc_bundle "$root" "$staged_app"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'sign_developer_id_bundle "$root" "$staged_app" "$LIDMUTE_DEVELOPER_IDENTITY"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'notarize_and_staple "$staged_app" "$LIDMUTE_NOTARY_PROFILE" "$staging"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'install_staged_bundle "$root" "$staged_app" "$app"' "$root/Scripts/make-app-bundle.sh"
! grep -Fq 'codesign --force --deep --sign' "$root/Scripts/make-app-bundle.sh"
print "PASS release packaging source contract"
```

- [ ] **Step 14: Run source-contract test and verify RED**

Run: `LIDMUTE_TEST_SKIP_IDENTITY_LOOKUP=1 zsh Scripts/test-release-packaging.sh`

Expected: FAIL because the current packaging script has no Release configuration, staging directory, or explicit nested signing branches.

- [ ] **Step 15: Refactor make-app-bundle around safe staging and Release-only packaging**

At the top of `Scripts/make-app-bundle.sh`, source the library, resolve `app` through `validate_output_path`, set `mode="$(resolve_signing_mode "${LIDMUTE_SIGNING_MODE:-}")"`, and add `--configuration release` to the same `build_args` used for both build and `--show-bin-path`.

Create staging only after path validation:

```zsh
dist="$root/dist"
mkdir -p -- "$dist"
staging="$(mktemp -d "$dist/.lidmute-stage.XXXXXX")"
trap 'cleanup_staging "$root" "$staging"' EXIT INT TERM
staged_app="$staging/${app:t}"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
```

Build the entire bundle at `staged_app`; never delete the destination before build, signing, and verification succeed. Read both version values through `read_version_value` and insert them into generated `Info.plist`. Add `CFBundleIdentifier=local.lidmute.app` explicitly and verify the final signed identifier matches it. Write exactly one channel marker:

```zsh
case "$mode" in
  adhoc) print 'local-adhoc' > "$staged_app/Contents/Resources/BuildChannel.txt" ;;
  developer-id) print 'developer-id-notarized' > "$staged_app/Contents/Resources/BuildChannel.txt" ;;
esac
```

Call the signing branch, verify it, and only then call `install_staged_bundle`. That helper validates destination again, renames any existing valid destination to a uniquely named direct-child backup, renames the staged App into place, restores the backup if installation rename fails, and removes the validated backup only after success.

- [ ] **Step 16: Implement innermost-out signing and verification helpers**

Add exact-order functions to `Scripts/lib/release-packaging.zsh`:

```zsh
sign_adhoc_bundle() {
  local repo_root="$1" app="$2" entitlements="$1/Config/LidMuteRelease.entitlements"
  codesign --force --sign - "$app/Contents/MacOS/LidMuteNativeHost"
  codesign --force --sign - --entitlements "$entitlements" "$app/Contents/MacOS/LidMute"
  codesign --force --sign - --entitlements "$entitlements" "$app"
}

sign_developer_id_bundle() {
  local repo_root="$1" app="$2" identity="$3" entitlements="$1/Config/LidMuteRelease.entitlements"
  codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/LidMuteNativeHost"
  codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app/Contents/MacOS/LidMute"
  codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app"
}
```

Pass `repo_root` exactly as the first argument shown above. Neither signing function uses `--deep`. Both verification functions verify Native Host, main executable, and bundle individually with `codesign --verify --strict --verbose=2`; the ad-hoc verifier additionally runs `codesign --verify --deep --strict` as required for the local acceptance bundle. Capture `codesign -d --entitlements :-` and fail if it contains `get-task-allow`. Developer ID verification also asserts `flags` includes `runtime`, the identity/team are nonempty, and runs `spctl --assess --type execute --verbose=4`.

- [ ] **Step 17: Implement mandatory Developer ID notarization and stapling**

Implement `notarize_and_staple` by creating a notarization ZIP inside staging with `ditto -c -k --keepParent`, then:

```zsh
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
```

Run this on every Developer ID build after signing and before final verification/installation. Any nonzero status aborts the script while the previous destination remains intact. Do not offer a skip-notarization environment variable.

- [ ] **Step 18: Run packaging source-contract tests and verify GREEN**

Run: `LIDMUTE_TEST_SKIP_IDENTITY_LOOKUP=1 zsh Scripts/test-release-packaging.sh`

Expected: all policy/source-contract checks PASS; source contains no `codesign --force --deep --sign` and does contain Release, same-filesystem staging, explicit branches, notarization, and safe install.

- [ ] **Step 19: Add failing ad-hoc end-to-end smoke assertions**

Update `Scripts/run-smoke-check.sh` to package with an explicit isolated scratch and output under `dist`, then assert:

```zsh
LIDMUTE_SIGNING_MODE=adhoc LIDMUTE_SCRATCH_PATH="$scratch" \
  LIDMUTE_APP_PATH="$root/dist/LidMute.app" zsh Scripts/make-app-bundle.sh
app="$root/dist/LidMute.app"
[[ "$(<"$app/Contents/Resources/BuildChannel.txt")" == "local-adhoc" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Version.plist)" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Config/Version.plist)" ]]
codesign --verify --deep --strict --verbose=2 "$app"
! codesign -d --entitlements :- "$app" 2>&1 | grep -q 'get-task-allow'
file "$app/Contents/MacOS/LidMute" | grep -q 'Mach-O'
```

Also assert captured packaging output contains `本地验收包，不可公开分发` and `configuration: release`. Capture output with `tee` to a file inside the task-specific scratch, not the repository.

- [ ] **Step 20: Run ad-hoc smoke and verify RED**

Run: `zsh Scripts/run-smoke-check.sh`

Expected: FAIL on the new Release provenance/channel-marker/output-label checks until the main script prints those exact messages and invokes the completed helpers.

- [ ] **Step 21: Complete ad-hoc terminal labeling and provenance checks**

Make `make-app-bundle.sh` print before building:

```text
LidMute packaging configuration: release
LidMute signing mode: adhoc
本地验收包，不可公开分发
```

After `--show-bin-path`, require its path to contain `/release` as a path component and retain the existing stale-source checks against both the App and Host binary. Fail with exit 67 if provenance is not Release.

- [ ] **Step 22: Run ad-hoc end-to-end smoke and verify GREEN**

Run: `zsh Scripts/run-smoke-check.sh`

Expected: `PASS LidMute smoke check`; the bundle is Release, `local-adhoc`, version-controlled, strictly signed, has no debug entitlement, includes one extension directory, and is explicitly unsuitable for public distribution.

- [ ] **Step 23: Add and run deterministic Developer ID failure tests without credentials**

Append to `Scripts/test-release-packaging.sh` subprocess tests that invoke the real entry point with an empty identity and then an empty profile, each with a safe temporary output and isolated scratch. Assert nonzero status, assert output contains the missing variable name, assert no destination App was installed, and assert output does not contain `本地验收包`:

```zsh
if LIDMUTE_SIGNING_MODE=developer-id LIDMUTE_DEVELOPER_IDENTITY='' \
   LIDMUTE_NOTARY_PROFILE='profile' LIDMUTE_APP_PATH="$fixture/repo/dist/Fail.app" \
   zsh "$root/Scripts/make-app-bundle.sh" >"$fixture/missing-identity.log" 2>&1; then exit 1; fi
grep -Fq 'LIDMUTE_DEVELOPER_IDENTITY is required' "$fixture/missing-identity.log"
! grep -Fq '本地验收包' "$fixture/missing-identity.log"
[[ ! -e "$fixture/repo/dist/Fail.app" ]]
```

Use the real repository `dist` for the actual entry-point invocation because safe path enforcement intentionally rejects the fake repo path; direct helper tests continue to use the fixture. Repeat for `LIDMUTE_NOTARY_PROFILE`, with a unique safe direct-child output, and remove only those exact test outputs through the safe cleanup helper.

Run: `LIDMUTE_TEST_SKIP_IDENTITY_LOOKUP=1 zsh Scripts/test-release-packaging.sh`

Expected: PASS and both Developer ID attempts fail before build/signing, never produce an App, and never mention ad-hoc fallback.

- [ ] **Step 24: Document health, privacy, and both release channels**

Update both READMEs with the same factual content:

- “当前没有活动音频” is healthy; CoreAudio/lid/storage failures are shown separately.
- Chrome connected means a valid heartbeat no older than 6 seconds, refreshed every 2 seconds; moving the App may require the in-app one-click manifest repair.
- Ordinary audible tabs store complete URLs locally, including query and fragment, which may contain search terms, identifiers, or tokens.
- Incognito tab-level evidence is ignored and never persisted or logged.
- “清空” removes observation data but preserves Chrome registration.
- Default/`adhoc` command: `LIDMUTE_SIGNING_MODE=adhoc zsh Scripts/make-app-bundle.sh`; output is local-only.
- Developer ID command requires exact `LIDMUTE_DEVELOPER_IDENTITY` and `LIDMUTE_NOTARY_PROFILE`; every such build is notarized and stapled, with no fallback.
- Version updates edit only `Config/Version.plist`.
- Final distribution still needs physical MacBook, route-switch, and clean-machine Gatekeeper acceptance.

Remove any statement that implies an ad-hoc bundle is an Apple-verified public installer.

- [ ] **Step 25: Run credential-free final automated acceptance**

Run:

```bash
swift test
node --test ChromeExtension/service-worker.test.mjs
LIDMUTE_TEST_SKIP_IDENTITY_LOOKUP=1 zsh Scripts/test-release-packaging.sh
zsh Scripts/run-smoke-check.sh
codesign --verify --deep --strict --verbose=2 dist/LidMute.app
```

Expected: all exit 0; all Swift/extension/policy tests pass; the smoke bundle is Release and marked `local-adhoc`; strict signature succeeds; no test claims Developer ID/notarization success without credentials.

- [ ] **Step 26: Run credentialed Developer ID acceptance on the release machine**

Export the release machine's exact existing credential names, then run:

```bash
test -n "$LIDMUTE_DEVELOPER_IDENTITY"
test -n "$LIDMUTE_NOTARY_PROFILE"
LIDMUTE_SIGNING_MODE=developer-id \
LIDMUTE_DEVELOPER_IDENTITY="$LIDMUTE_DEVELOPER_IDENTITY" \
LIDMUTE_NOTARY_PROFILE="$LIDMUTE_NOTARY_PROFILE" \
zsh Scripts/make-app-bundle.sh
codesign --verify --deep --strict --verbose=2 dist/LidMute.app
codesign -d --verbose=4 dist/LidMute.app 2>&1 | grep -q 'flags=.*runtime'
spctl --assess --type execute --verbose=4 dist/LidMute.app
xcrun stapler validate dist/LidMute.app
test "$(<dist/LidMute.app/Contents/Resources/BuildChannel.txt)" = 'developer-id-notarized'
```

Expected: both preflight checks and every packaging/verification command exit 0; packaging output includes the successful `notarytool` submission result; `spctl` reports accepted with the configured Developer ID origin; stapler validates the ticket; the channel is `developer-id-notarized`. Credential names remain release-machine environment values and are never written to the repository.

- [ ] **Step 27: Perform physical and clean-machine final acceptance**

Use the Developer ID artifact from Step 26 and record pass/fail evidence for each fixed scenario:

1. Move the App to `/Applications`, launch it on a clean macOS 15-or-newer machine, and confirm Gatekeeper opens it without bypass instructions.
2. Register Chrome, move the App once, confirm health reports a manifest path mismatch, click “修复 Chrome 通信路径”, refresh the extension, and confirm a fresh heartbeat changes state to connected within 6 seconds.
3. Disconnect the extension and confirm connected expires after 6 seconds rather than remaining alive because of a stale PID.
4. On a MacBook, exercise physical close/open and screen sleep while playing audio; confirm the protection/recovery invariants from Tasks 1-9 and no automatic media-key toggle.
5. Switch built-in A → Bluetooth/USB/display B → built-in A during protection; confirm no write targets B and A is safely re-protected/restored by UID.
6. Play an ordinary Chrome URL containing query and fragment, confirm the disclosure matches persistence, then clear observations and confirm restart does not resurrect it while Chrome remains registered.
7. Enable extension incognito access, play audio in an incognito tab, and confirm no title, URL, raw frame, or tab evidence appears in files, UI history, or Console diagnostics.

Expected: all seven scenarios pass. A failure blocks public distribution and is filed with the exact OS version, hardware/audio route, App version/build from `Config/Version.plist`, signing channel, and non-sensitive failure category; do not attach private URLs or raw Chrome frames.

- [ ] **Step 28: Request independent verification and commit Task 11**

Have a fresh verifier review the Task 11 diff and evidence, specifically safe-path deletion boundaries, lack of ad-hoc fallback, signature order, release entitlements, notarization/stapling, privacy copy, and the seven manual scenarios. Resolve every release-blocking finding, rerun Steps 25-27 as applicable, then commit:

```bash
git add Scripts/lib/release-packaging.zsh Scripts/test-release-packaging.sh Scripts/make-app-bundle.sh Scripts/run-smoke-check.sh Config/Version.plist Config/LidMuteRelease.entitlements README.md README.zh-CN.md
git commit -m "build: harden release signing and notarization"
```
