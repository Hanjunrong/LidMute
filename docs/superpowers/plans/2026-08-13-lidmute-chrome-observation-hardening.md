# LidMute Chrome Observation Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Chrome observation lossless, privacy-correct, bounded to 5,000 persisted events, and safe under concurrent Native Host acceptance, App consumption, crashes, retries, and clear-all.

**Architecture:** A shared `ObservationStore` in `LidMuteCore` owns the cross-process lock, monotonic generation, durable Chrome inbox, ordered deduplication, bounded event JSONL, and atomic clear barrier. The Native Host validates a complete length-prefixed frame and calls one durable accept operation before emitting a terminal ACK; the App consumes only complete inbox records through a persisted cursor and updates its presentation incrementally. The Chrome extension serializes every outbox mutation through one promise queue so ACK order and reconnects cannot race.

**Tech Stack:** Swift 6, Foundation, Darwin `flock`/`fsync`, Swift Testing cases hosted by the protection plan's standard SwiftPM `LidMuteCoreTests` `.testTarget`, Chrome Manifest V3 JavaScript, Node `node:test`; macOS 15 minimum; no third-party runtime dependencies.

## Global Constraints

- This plan depends on Task 1 of `docs/superpowers/plans/2026-08-13-lidmute-protection-recovery-hardening.md` first converting `Tests/LidMuteCoreBehavior` into `.testTarget(name: "LidMuteCoreTests", dependencies: ["LidMuteCore"], path: "Tests/LidMuteCoreTests")`; every Swift RED/GREEN command below assumes that target exists.
- Task 7 depends only on protection Task 1 and may proceed while later protection tasks are in progress. Task 9's App integration has a hard dependency on protection Task 6 being merged and green, because Task 6 produces `AppLifecycleState` with `recovering`, `ready`, and `recoveryBlocked(SpeakerRecoveryOutcome)`, plus `ApplicationLifecycleCoordinator.state`; `AppViewModel` must not call `ChromeInboxConsumer.consumeAvailable()` or start its Chrome timer before lifecycle state is `ready`.
- `Sources/LidMuteApp/AppViewModel.swift` ownership is strictly serial: protection Task 6 -> this plan Task 9 -> health/release Task 10. Do not run those integration tasks concurrently.
- Minimum supported version remains macOS 15.
- Do not add third-party runtime dependencies or SQLite.
- Native Messaging frames use a 4-byte little-endian UTF-8 byte length and have a hard maximum of 262,144 bytes.
- `eventId` and `extensionSessionId` must each be RFC 4122 UUID strings no longer than 64 UTF-8 bytes.
- `title` is limited to 4,096 UTF-8 bytes; URL to 16,384 bytes; status and mute reason to 64 bytes; extension ID to 128 bytes.
- A normal `tab_audio_started` frame is terminally `accepted` only after the normalized record and its containing file have crossed the `fsync` commit point while holding the shared bridge lock.
- Terminal dispositions are exactly `accepted`, `duplicate`, `ignored_incognito`, and `rejected_permanent`; `retryable_failure` retains the extension outbox item.
- Incognito title, URL, and raw payload must never enter inbox, event storage, dedup storage, or diagnostic logs.
- Normal-tab evidence persists the complete URL, including query and fragment.
- Deduplication retains the most recently accepted 4,096 event IDs in acceptance order, not UUID lexical order.
- Disk event history retains at most the newest 5,000 valid events.
- Observation clear deletes events, inbox, dedup IDs, cursor/remainder, and in-memory Chrome evidence, but preserves Native Messaging manifest, registered origin/extension ID, and executable path registration.
- Clear, Native Host accept, and App consume share one cross-process lock and one monotonic generation barrier.
- Storage corruption, permission failure, and capacity failure must produce an explicit health state; they must not be silently skipped.
- No automatic media-key behavior is introduced by Chrome evidence.

---

### Task 7: Native Host validated framing, durable ACK, and idempotent inbox

**Files:**
- Create: `Sources/LidMuteCore/ObservationStore.swift`
- Create: `Sources/LidMuteCore/ChromeNativeMessaging.swift`
- Modify: `Package.swift`
- Modify: `Sources/LidMuteCore/ChromeProtocol.swift`
- Modify: `Sources/LidMuteNativeHost/main.swift`
- Test: `Tests/LidMuteCoreTests/ChromeNativeMessagingTests.swift`
- Test: `Tests/LidMuteCoreTests/ObservationStoreAcceptanceTests.swift`

**Interfaces:**
- Consumes: the protection plan's standard `LidMuteCoreTests` test target; `ChromeTabEvidence` from `Sources/LidMuteCore/Models.swift`.
- Produces: `ObservationPaths.init(root:)`, `ObservationStore.init(paths:fileSystem:)`, `ObservationStore.accept(_:) -> ChromeAcceptDisposition`, `ChromeFrameDecoder.decode(_:) -> ChromeValidatedFrame`, `NativeMessageFramer.feed(_:) -> [Data]`, `NativeHostSession.receive(_:) -> [ChromeAcknowledgement]`, and terminal/retryable ACK JSON consumed by Task 8.
- Produces for Task 9: `ObservationStore.withExclusiveLock(_:)`, `ObservationStore.currentGeneration()`, inbox records carrying `generation`, and ordered dedup metadata stored under the same lock.

- [ ] **Step 1: Write framing RED tests for split prefixes, split UTF-8 payloads, glued frames, and EOF remainder**

Create `Tests/LidMuteCoreTests/ChromeNativeMessagingTests.swift` with these concrete helpers and assertions:

```swift
import Foundation
import Testing
@testable import LidMuteCore

private func wire(_ payload: Data) -> Data {
    var count = UInt32(payload.count).littleEndian
    return Data(bytes: &count, count: 4) + payload
}

@Test func framerWaitsForCompletePrefixAndPayload() throws {
    let payload = Data(#"{"title":"音乐🎵"}"#.utf8)
    let framed = wire(payload)
    let framer = NativeMessageFramer(maxFrameBytes: 262_144)
    #expect(try framer.feed(framed.prefix(1)).isEmpty)
    #expect(try framer.feed(framed.dropFirst(1).prefix(5)).isEmpty)
    #expect(try framer.feed(framed.dropFirst(6)) == [payload])
}

@Test func framerReturnsTwoGluedFramesAndKeepsTrailingHalfFrame() throws {
    let first = Data(#"{"v":1}"#.utf8)
    let second = Data(#"{"v":2}"#.utf8)
    let third = Data(#"{"v":3}"#.utf8)
    let thirdWire = wire(third)
    let framer = NativeMessageFramer(maxFrameBytes: 262_144)
    #expect(try framer.feed(wire(first) + wire(second) + thirdWire.prefix(6)) == [first, second])
    #expect(framer.bufferedByteCount == 6)
    #expect(try framer.feed(thirdWire.dropFirst(6)) == [third])
}

@Test func framerRejectsOversizeBeforeBufferingPayload() throws {
    var count = UInt32(262_145).littleEndian
    let prefix = Data(bytes: &count, count: 4)
    #expect(throws: NativeMessageFramingError.frameTooLarge(262_145)) {
        try NativeMessageFramer(maxFrameBytes: 262_144).feed(prefix)
    }
}
```

- [ ] **Step 2: Run the framing tests and verify RED**

Run: `swift test --filter ChromeNativeMessagingTests`

Expected: FAIL to compile with `cannot find 'NativeMessageFramer' in scope` and `cannot find 'NativeMessageFramingError' in scope`.

- [ ] **Step 3: Implement the minimal incremental length-prefixed framer**

Add the following interface and state machine to `Sources/LidMuteCore/ChromeNativeMessaging.swift`; parsing must remove bytes only after a complete frame is available:

```swift
import Foundation

public enum NativeMessageFramingError: Error, Equatable {
    case frameTooLarge(Int)
}

public final class NativeMessageFramer: @unchecked Sendable {
    private var buffer = Data()
    private let maxFrameBytes: Int
    public var bufferedByteCount: Int { buffer.count }

    public init(maxFrameBytes: Int = 262_144) {
        self.maxFrameBytes = maxFrameBytes
    }

    public func feed<S: DataProtocol>(_ bytes: S) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes {
                Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard length <= maxFrameBytes else {
                throw NativeMessageFramingError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            frames.append(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }
        return frames
    }
}
```

- [ ] **Step 4: Run the framing tests and verify GREEN**

Run: `swift test --filter ChromeNativeMessagingTests`

Expected: PASS for the three framing tests.

- [ ] **Step 5: Commit the framing checkpoint**

```bash
git add Sources/LidMuteCore/ChromeNativeMessaging.swift Tests/LidMuteCoreTests/ChromeNativeMessagingTests.swift
git commit -m "feat: parse incremental Chrome native frames"
```

- [ ] **Step 6: Add RED tests for exact schema, byte limits, UUIDs, full URL preservation, and incognito classification**

Append these builders and tests to `Tests/LidMuteCoreTests/ChromeNativeMessagingTests.swift`:

```swift
private let eventID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

private func validPayload(incognito: Bool = false, eventIDText: String? = nil) -> Data {
    Data(#"{"v":1,"type":"tab_audio_started","eventId":"\#(eventIDText ?? eventID.uuidString)","extensionSessionId":"\#(sessionID.uuidString)","seq":"7","sentAt":"2026-08-13T00:00:00Z","tab":{"windowId":1,"tabId":2,"index":0,"title":"搜索","url":"https://example.com/watch?q=secret#chapter","status":"complete","audible":true,"muted":{"value":false,"reason":null,"extensionId":null},"active":true,"pinned":false,"incognito":\#(incognito)}}"#.utf8)
}

@Test func decoderPreservesCompleteNormalURL() throws {
    let frame = try ChromeFrameDecoder().decode(validPayload())
    #expect(frame.eventID == eventID)
    #expect(frame.evidence.url == "https://example.com/watch?q=secret#chapter")
    #expect(frame.privacy == .persist)
}

@Test func decoderClassifiesIncognitoBeforePersistence() throws {
    let frame = try ChromeFrameDecoder().decode(validPayload(incognito: true))
    #expect(frame.privacy == .ignoreIncognito)
}

@Test(arguments: [
    Data("not-json".utf8),
    Data(#"{"v":2}"#.utf8),
    validPayload(eventIDText: "not-a-uuid"),
]) func decoderRejectsPermanentProtocolErrors(_ payload: Data) {
    #expect(throws: ChromeFrameValidationError.self) {
        try ChromeFrameDecoder().decode(payload)
    }
}

@Test func decoderMeasuresUTF8BytesRatherThanCharacterCount() {
    let oversizedTitle = String(repeating: "界", count: 1_366) // 4,098 UTF-8 bytes
    let replaced = String(decoding: validPayload(), as: UTF8.self)
        .replacingOccurrences(of: "搜索", with: oversizedTitle)
    #expect(throws: ChromeFrameValidationError.titleTooLong) {
        try ChromeFrameDecoder().decode(Data(replaced.utf8))
    }
}
```

- [ ] **Step 7: Run schema tests and verify RED**

Run: `swift test --filter ChromeNativeMessagingTests`

Expected: FAIL to compile because `ChromeFrameDecoder`, `ChromeValidatedFrame`, `ChromeFramePrivacy`, and `ChromeFrameValidationError` do not exist.

- [ ] **Step 8: Implement exact wire decoding and validation before constructing persistence evidence**

Replace the permissive decode entry point in `Sources/LidMuteCore/ChromeProtocol.swift` with these public contracts and private wire DTOs; use `Data.count` for every UTF-8 limit and `UUID(uuidString:)` for IDs:

```swift
public enum ChromeFramePrivacy: Sendable { case persist, ignoreIncognito }

public struct ChromeValidatedFrame: Sendable {
    public let eventID: UUID
    public let extensionSessionID: UUID
    public let evidence: ChromeTabEvidence
    public let privacy: ChromeFramePrivacy
}

public enum ChromeFrameValidationError: Error, Equatable {
    case malformedJSON, unsupportedVersion, unsupportedType, notAudible
    case invalidEventID, invalidSessionID, titleTooLong, urlTooLong
    case statusTooLong, muteReasonTooLong, extensionIDTooLong
}

public struct ChromeFrameDecoder: Sendable {
    public init() {}

    public func decode(_ data: Data) throws -> ChromeValidatedFrame {
        let wire: WireFrame
        do { wire = try JSONDecoder().decode(WireFrame.self, from: data) }
        catch { throw ChromeFrameValidationError.malformedJSON }
        guard wire.v == 1 else { throw ChromeFrameValidationError.unsupportedVersion }
        guard wire.type == "tab_audio_started" else { throw ChromeFrameValidationError.unsupportedType }
        guard wire.tab.audible else { throw ChromeFrameValidationError.notAudible }
        guard Data(wire.eventId.utf8).count <= 64, let eventID = UUID(uuidString: wire.eventId)
        else { throw ChromeFrameValidationError.invalidEventID }
        guard Data(wire.extensionSessionId.utf8).count <= 64,
              let sessionID = UUID(uuidString: wire.extensionSessionId)
        else { throw ChromeFrameValidationError.invalidSessionID }
        guard Data(wire.tab.title.utf8).count <= 4_096 else { throw ChromeFrameValidationError.titleTooLong }
        guard Data(wire.tab.url.utf8).count <= 16_384 else { throw ChromeFrameValidationError.urlTooLong }
        guard Data(wire.tab.status.utf8).count <= 64 else { throw ChromeFrameValidationError.statusTooLong }
        guard wire.tab.muted.reason.map({ Data($0.utf8).count <= 64 }) ?? true
        else { throw ChromeFrameValidationError.muteReasonTooLong }
        guard wire.tab.muted.extensionId.map({ Data($0.utf8).count <= 128 }) ?? true
        else { throw ChromeFrameValidationError.extensionIDTooLong }
        let evidence = ChromeTabEvidence(
            sessionID: sessionID.uuidString, windowID: wire.tab.windowId,
            tabID: wire.tab.tabId, index: wire.tab.index, title: wire.tab.title,
            url: wire.tab.url, audible: true, muted: wire.tab.muted.value,
            isActive: wire.tab.active, isPinned: wire.tab.pinned,
            isIncognito: wire.tab.incognito
        )
        return ChromeValidatedFrame(
            eventID: eventID, extensionSessionID: sessionID, evidence: evidence,
            privacy: wire.tab.incognito ? .ignoreIncognito : .persist
        )
    }
}
```

Define `WireFrame`, `WireTab`, and `WireMuted` with non-optional required fields matching the JSON keys in the test. Do not log the caught decoder error or raw payload.

- [ ] **Step 9: Run schema tests and verify GREEN**

Run: `swift test --filter ChromeNativeMessagingTests`

Expected: PASS for framing, UUID, byte-limit, privacy classification, and full URL tests.

- [ ] **Step 10: Commit the validated protocol checkpoint**

```bash
git add Sources/LidMuteCore/ChromeProtocol.swift Tests/LidMuteCoreTests/ChromeNativeMessagingTests.swift
git commit -m "feat: validate Chrome observation frames"
```

- [ ] **Step 11: Write durable acceptance RED tests for fsync ordering, duplicate order, incognito zero persistence, and generation**

Create `Tests/LidMuteCoreTests/ObservationStoreAcceptanceTests.swift` with a fault-injectable filesystem spy and these assertions:

```swift
import Foundation
import Testing
@testable import LidMuteCore

final class RecordingObservationFileSystem: ObservationFileSystem, @unchecked Sendable {
    var operations: [String] = []
    var failFileSync = false
    private var files: [URL: Data] = [:]
    func read(_ url: URL) throws -> Data { files[url] ?? Data() }
    func coordinatedAppend(_ data: Data, to url: URL) throws {
        operations.append("write:\(url.lastPathComponent)")
        files[url, default: Data()].append(data)
    }
    func atomicWrite(_ data: Data, to url: URL, permissions: Int16) throws {
        operations.append("atomic:\(url.lastPathComponent)"); files[url] = data
    }
    func syncFile(_ url: URL) throws {
        operations.append("fsync:\(url.lastPathComponent)")
        if failFileSync { throw CocoaError(.fileWriteOutOfSpace) }
    }
    func syncDirectory(_ url: URL) throws { operations.append("fsync-dir:\(url.lastPathComponent)") }
    func ensurePrivateDirectory(_ url: URL) throws { operations.append("mkdir:\(url.lastPathComponent)") }
    func truncate(_ url: URL) throws { files[url] = Data() }
    func removeIfPresent(_ url: URL) throws { files[url] = nil }
}

@Test func acceptedOccursOnlyAfterRecordAndMetadataAreSynced() throws {
    let fs = RecordingObservationFileSystem()
    let paths = ObservationPaths(root: URL(fileURLWithPath: "/tmp/lidmute-store-test"))
    let store = ObservationStore(paths: paths, fileSystem: fs, lock: InProcessObservationLock())
    let result = try store.accept(try ChromeFrameDecoder().decode(validPayload()))
    #expect(result == .accepted(eventID))
    #expect(fs.operations.firstIndex(of: "write:chrome-inbox.jsonl")! < fs.operations.firstIndex(of: "fsync:chrome-inbox.jsonl")!)
    #expect(fs.operations.contains("fsync:chrome-dedup.json"))
}

@Test func fsyncFailureIsRetryableAndDoesNotPublishAccepted() throws {
    let fs = RecordingObservationFileSystem(); fs.failFileSync = true
    let store = ObservationStore(paths: .init(root: URL(fileURLWithPath: "/tmp/retry")), fileSystem: fs, lock: InProcessObservationLock())
    #expect(throws: ObservationStoreError.retryablePersistenceFailure) {
        try store.accept(try ChromeFrameDecoder().decode(validPayload()))
    }
}

@Test func duplicateIsTerminalWithoutSecondInboxRecord() throws {
    let fixture = try ObservationStoreFixture()
    let frame = try ChromeFrameDecoder().decode(validPayload())
    #expect(try fixture.store.accept(frame) == .accepted(eventID))
    #expect(try fixture.store.accept(frame) == .duplicate(eventID))
    #expect(try fixture.store.readInboxRecords().count == 1)
}

@Test func incognitoIsTerminalWithZeroObservationPersistence() throws {
    let fixture = try ObservationStoreFixture()
    let frame = try ChromeFrameDecoder().decode(validPayload(incognito: true))
    #expect(try fixture.store.accept(frame) == .ignoredIncognito(eventID))
    #expect(try fixture.store.readInboxRecords().isEmpty)
    #expect(try fixture.store.acceptedEventIDs().isEmpty)
    #expect(try fixture.persistedBytes().contains(Data("secret".utf8)) == false)
}
```

Implement the test-only `ObservationStoreFixture` with `FileManager.default.temporaryDirectory`, cleanup in `deinit`, and real `POSIXObservationFileSystem`; this ensures the duplicate test exercises process-restart persistence instead of only the spy.

- [ ] **Step 12: Run acceptance tests and verify RED**

Run: `swift test --filter ObservationStoreAcceptanceTests`

Expected: FAIL to compile because `ObservationStore`, `ObservationPaths`, `ObservationFileSystem`, and lock types are undefined.

- [ ] **Step 13: Implement the shared paths, lock, durable inbox record, and acceptance-order dedup interfaces**

Add the following contracts to `Sources/LidMuteCore/ObservationStore.swift`:

```swift
public struct ObservationPaths: Sendable {
    public let root, lock, generation, inbox, dedup, cursor, events: URL
    public init(root: URL) {
        self.root = root
        lock = root.appending(path: "observation.lock")
        generation = root.appending(path: "observation-generation")
        inbox = root.appending(path: "chrome-inbox.jsonl")
        dedup = root.appending(path: "chrome-dedup.json")
        cursor = root.appending(path: "chrome-cursor.json")
        events = root.appending(path: "events.jsonl")
    }
}

public protocol ObservationLocking: Sendable {
    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T
}

public protocol ObservationFileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    func coordinatedAppend(_ data: Data, to url: URL) throws
    func atomicWrite(_ data: Data, to url: URL, permissions: Int16) throws
    func syncFile(_ url: URL) throws
    func syncDirectory(_ url: URL) throws
    func ensurePrivateDirectory(_ url: URL) throws
    func truncate(_ url: URL) throws
    func removeIfPresent(_ url: URL) throws
}

public struct ChromeInboxRecord: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let eventID: UUID
    public let acceptedAt: Date
    public let evidence: ChromeTabEvidence
}

public enum ChromeAcceptDisposition: Equatable, Sendable {
    case accepted(UUID), duplicate(UUID), ignoredIncognito(UUID)
}

public enum ObservationStoreError: Error, Equatable {
    case retryablePersistenceFailure
    case corruptMetadata(String)
}

public final class ObservationStore: @unchecked Sendable {
    public init(paths: ObservationPaths, fileSystem: ObservationFileSystem = POSIXObservationFileSystem(), lock: ObservationLocking? = nil)
    public func accept(_ frame: ChromeValidatedFrame) throws -> ChromeAcceptDisposition
    public func currentGeneration() throws -> UInt64
    public func readInboxRecords() throws -> [ChromeInboxRecord]
    public func acceptedEventIDs() throws -> [UUID]
    public func withExclusiveLock<T>(_ body: () throws -> T) throws -> T
}
```

`POSIXObservationLock` must use an `NSRecursiveLock` and a per-thread recursion depth around one open `observation.lock` descriptor: depth zero calls `flock(fd, LOCK_EX)`, nested calls on the same thread reuse it, and the final unwind calls `flock(fd, LOCK_UN)`. This makes Task 9's consumer transaction safe when its event store uses the exact same injected lock instance; creating a second lock object for nested operations is forbidden. The lock file mode is `0600`. `accept` must, within this lock: read generation; return `ignoredIncognito` before serializing evidence; read ordered dedup; return `duplicate` if found; encode one `ChromeInboxRecord` plus newline; append it; `fsync` inbox; append the ID to ordered dedup, cap with `suffix(4_096)`, atomically write mode `0600`, `fsync` it and synchronize the parent directory when a file is first created/replaced. Map lock, permission, capacity, write, and sync failures to `.retryablePersistenceFailure` without adding the ID to the in-memory accepted set.

- [ ] **Step 14: Run durable acceptance tests and verify GREEN**

Run: `swift test --filter ObservationStoreAcceptanceTests`

Expected: PASS, including zero persisted incognito bytes and duplicate acceptance after constructing a second `ObservationStore` over the same fixture root.

- [ ] **Step 15: Add RED host-session tests for terminal ACKs, retryable failures, and malformed payloads**

Append to `Tests/LidMuteCoreTests/ChromeNativeMessagingTests.swift`:

```swift
@Test func hostAcknowledgesOnlyAfterStoreDisposition() throws {
    let accepting = FakeChromeAccepting(result: .success(.accepted(eventID)))
    let session = NativeHostSession(acceptor: accepting)
    let acks = try session.receive(wire(validPayload()))
    #expect(acks == [.init(eventID: eventID, disposition: .accepted)])
    #expect(accepting.acceptCount == 1)
}

@Test func hostReturnsRetryableFailureWhenDurabilityFails() throws {
    let acceptor = FakeChromeAccepting(result: .failure(.retryablePersistenceFailure))
    let ack = try NativeHostSession(acceptor: acceptor).receive(wire(validPayload())).only
    #expect(ack.disposition == .retryableFailure)
    #expect(ack.eventID == eventID)
}

@Test func hostPermanentlyRejectsValidIDWithBadSchema() throws {
    let bad = String(decoding: validPayload(), as: UTF8.self)
        .replacingOccurrences(of: "\"audible\":true", with: "\"audible\":false")
    let ack = try NativeHostSession(acceptor: FakeChromeAccepting.neverCalled)
        .receive(wire(Data(bad.utf8))).only
    #expect(ack == .init(eventID: eventID, disposition: .rejectedPermanent))
}
```

The test helper `FakeChromeAccepting` conforms to `ChromeFrameAccepting { func accept(_:) throws -> ChromeAcceptDisposition }`; `.only` is a test extension that requires exactly one array element.

- [ ] **Step 16: Run host-session tests and verify RED**

Run: `swift test --filter ChromeNativeMessagingTests`

Expected: FAIL to compile because `NativeHostSession`, `ChromeAcknowledgement`, `ChromeAckDisposition`, and `ChromeFrameAccepting` do not exist.

- [ ] **Step 17: Implement ACK mapping and replace the Native Host's unvalidated append loop**

Add these contracts to `ChromeNativeMessaging.swift`:

```swift
public enum ChromeAckDisposition: String, Codable, Sendable {
    case accepted, duplicate, ignoredIncognito = "ignored_incognito"
    case rejectedPermanent = "rejected_permanent"
    case retryableFailure = "retryable_failure"
}

public struct ChromeAcknowledgement: Codable, Equatable, Sendable {
    public let version = 1
    public let type = "ack"
    public let eventID: UUID?
    public let disposition: ChromeAckDisposition
    enum CodingKeys: String, CodingKey { case version = "v", type, eventID = "eventId", disposition }
}

public protocol ChromeFrameAccepting: Sendable {
    func accept(_ frame: ChromeValidatedFrame) throws -> ChromeAcceptDisposition
}

public final class NativeHostSession {
    public init(acceptor: ChromeFrameAccepting, decoder: ChromeFrameDecoder = .init(), framer: NativeMessageFramer = .init())
    public func receive<S: DataProtocol>(_ bytes: S) throws -> [ChromeAcknowledgement]
}
```

`receive` must decode each complete payload, map store results to terminal dispositions, map `ObservationStoreError.retryablePersistenceFailure` to retryable ACK, and map permanent validation errors to `rejected_permanent` only when a bounded valid UUID `eventId` can be extracted using a small `EventIDEnvelope`; if no safe ID can be parsed, throw `NativeHostProtocolError.unaddressableMalformedFrame` so `main.swift` writes a generic stderr reason and disconnects without raw payload.

Replace `Sources/LidMuteNativeHost/main.swift` lines 21–70 with a loop that constructs `ObservationStore` and `NativeHostSession`, passes every `availableData` chunk to `receive`, and writes each encoded `ChromeAcknowledgement` through a `writeNativeMessage(_:)` helper. Do not ACK at EOF if `framer.bufferedByteCount > 0`; log only `partial_frame_at_eof` and exit nonzero.

Update `Package.swift` so the executable can import the shared protocol/store module:

```swift
.executableTarget(name: "LidMuteNativeHost", dependencies: ["LidMuteCore"]),
```

- [ ] **Step 18: Run all Native Host and acceptance tests and verify GREEN**

Run: `swift test --filter ChromeNativeMessagingTests && swift test --filter ObservationStoreAcceptanceTests`

Expected: PASS; the fsync-failure test receives only `retryable_failure`, invalid schema never calls the acceptor, and incognito never reaches persistence.

- [ ] **Step 19: Commit Task 7**

```bash
git add Package.swift Sources/LidMuteCore/ObservationStore.swift Sources/LidMuteCore/ChromeNativeMessaging.swift Sources/LidMuteCore/ChromeProtocol.swift Sources/LidMuteNativeHost/main.swift Tests/LidMuteCoreTests/ChromeNativeMessagingTests.swift Tests/LidMuteCoreTests/ObservationStoreAcceptanceTests.swift
git commit -m "feat: durably accept validated Chrome observations"
```

---

### Task 8: Chrome extension serialized outbox and disposition-aware retry

**Files:**
- Modify: `ChromeExtension/service-worker.mjs`
- Modify: `ChromeExtension/service-worker.test.mjs`

**Interfaces:**
- Consumes: Task 7 ACK JSON `{ v: 1, type: "ack", eventId: string | null, disposition: "accepted" | "duplicate" | "ignored_incognito" | "rejected_permanent" | "retryable_failure" }`.
- Produces: exported `createOutboxController(storage, post, scheduleRetry)`, whose `enqueue(frame)`, `acknowledge(ack)`, and `flush()` operations are serialized; the existing Chrome listeners delegate to this controller.
- Produces: an outbox item is removed only for the four terminal Task 7 dispositions; retryable failure, disconnect, and post failure preserve it.

- [ ] **Step 1: Replace helper-only tests with RED race tests using a delayed in-memory storage fake**

Extend `ChromeExtension/service-worker.test.mjs` with:

```javascript
function deferred() {
  let resolve;
  const promise = new Promise((r) => { resolve = r; });
  return { promise, resolve };
}

function storageWith(outbox) {
  let value = { sessionId: crypto.randomUUID(), seq: outbox.length, outbox };
  return {
    session: {
      async get() { return structuredClone(value); },
      async set(patch) { value = { ...value, ...structuredClone(patch) }; }
    },
    snapshot: () => structuredClone(value)
  };
}

test('serializes crossed acknowledgements without resurrecting either event', async () => {
  const storage = storageWith([{ eventId: 'one' }, { eventId: 'two' }]);
  const gate = deferred();
  const controller = createOutboxController(storage.session, () => {}, () => {});
  const first = controller.acknowledge({ type: 'ack', eventId: 'one', disposition: 'accepted' });
  const second = controller.acknowledge({ type: 'ack', eventId: 'two', disposition: 'duplicate' });
  gate.resolve();
  await Promise.all([first, second]);
  assert.deepEqual(storage.snapshot().outbox, []);
});

test('removes only terminal dispositions and keeps retryable failure', async () => {
  for (const disposition of ['accepted', 'duplicate', 'ignored_incognito', 'rejected_permanent']) {
    const storage = storageWith([{ eventId: disposition }]);
    const controller = createOutboxController(storage.session, () => {}, () => {});
    await controller.acknowledge({ type: 'ack', eventId: disposition, disposition });
    assert.deepEqual(storage.snapshot().outbox, []);
  }
  const storage = storageWith([{ eventId: 'retry' }]);
  const controller = createOutboxController(storage.session, () => {}, () => {});
  await controller.acknowledge({ type: 'ack', eventId: 'retry', disposition: 'retryable_failure' });
  assert.equal(storage.snapshot().outbox.length, 1);
});

test('enqueue concurrent with ack preserves the new item', async () => {
  const storage = storageWith([{ eventId: 'old' }]);
  const controller = createOutboxController(storage.session, () => {}, () => {});
  await Promise.all([
    controller.acknowledge({ type: 'ack', eventId: 'old', disposition: 'accepted' }),
    controller.enqueue({ eventId: 'new' })
  ]);
  assert.deepEqual(storage.snapshot().outbox.map((item) => item.eventId), ['new']);
});
```

- [ ] **Step 2: Run extension tests and verify RED**

Run: `node --test ChromeExtension/service-worker.test.mjs`

Expected: FAIL at module import with `does not provide an export named 'createOutboxController'`.

- [ ] **Step 3: Implement one promise queue for every outbox read-modify-write**

Add this controller to `ChromeExtension/service-worker.mjs` and route `sendAudibleTab`, `acknowledge`, and `flushOutbox` through it:

```javascript
const TERMINAL_DISPOSITIONS = new Set([
  'accepted', 'duplicate', 'ignored_incognito', 'rejected_permanent'
]);

export function createOutboxController(storage, post, scheduleRetry) {
  let tail = Promise.resolve();
  const serial = (operation) => {
    const result = tail.then(operation, operation);
    tail = result.catch(() => {});
    return result;
  };

  return {
    enqueue(frame) {
      return serial(async () => {
        const current = await storage.get(['sessionId', 'seq', 'outbox']);
        const outbox = [...(current.outbox ?? []), frame].slice(-OUTBOX_LIMIT);
        await storage.set({ outbox });
      });
    },
    acknowledge(ack) {
      return serial(async () => {
        if (ack?.type !== 'ack' || !ack.eventId) return;
        if (ack.disposition === 'retryable_failure') {
          scheduleRetry();
          return;
        }
        if (!TERMINAL_DISPOSITIONS.has(ack.disposition)) return;
        const current = await storage.get(['outbox']);
        await storage.set({
          outbox: (current.outbox ?? []).filter((item) => item.eventId !== ack.eventId)
        });
      });
    },
    flush() {
      return serial(async () => {
        const current = await storage.get(['outbox']);
        for (const frame of current.outbox ?? []) post(frame);
      });
    }
  };
}
```

Create one controller instance after the native port is connected. `onMessage` calls `void controller.acknowledge(message)`. `onDisconnect` clears `nativePort`, keeps storage untouched, and schedules exponential retry delays capped at 60 seconds. Reset retry delay to one second only after a terminal ACK; repeated ACK for a missing ID is a successful no-op.

- [ ] **Step 4: Run race tests and verify GREEN**

Run: `node --test ChromeExtension/service-worker.test.mjs`

Expected: PASS for original serialization/replay tests and new crossed ACK, disposition, and enqueue-versus-ACK tests.

- [ ] **Step 5: Add RED reconnect tests proving replay does not mutate storage and retryable events survive**

Append:

```javascript
test('flush replays in order without deleting before acknowledgements', async () => {
  const storage = storageWith([{ eventId: 'one' }, { eventId: 'two' }]);
  const posted = [];
  const controller = createOutboxController(storage.session, (item) => posted.push(item.eventId), () => {});
  await controller.flush();
  await controller.flush();
  assert.deepEqual(posted, ['one', 'two', 'one', 'two']);
  assert.deepEqual(storage.snapshot().outbox.map((item) => item.eventId), ['one', 'two']);
});

test('duplicate and out-of-order terminal acks converge to an empty outbox', async () => {
  const storage = storageWith([{ eventId: 'one' }, { eventId: 'two' }]);
  const controller = createOutboxController(storage.session, () => {}, () => {});
  await Promise.all([
    controller.acknowledge({ type: 'ack', eventId: 'two', disposition: 'accepted' }),
    controller.acknowledge({ type: 'ack', eventId: 'one', disposition: 'accepted' }),
    controller.acknowledge({ type: 'ack', eventId: 'two', disposition: 'duplicate' })
  ]);
  assert.deepEqual(storage.snapshot().outbox, []);
});
```

- [ ] **Step 6: Run reconnect tests and verify RED if any listener still calls the old unsynchronized helpers**

Run: `node --test ChromeExtension/service-worker.test.mjs`

Expected before routing all production listeners through the controller: FAIL because a direct `acknowledge`/`flushOutbox` path mutates or reads storage outside `serial`; after the Step 7 wiring, all tests pass.

- [ ] **Step 7: Finish production wiring and remove direct outbox mutations**

Use `rg -n "storage\.session\.(get|set)|outbox" ChromeExtension/service-worker.mjs` and leave storage access only inside `state()` initialization and `createOutboxController`. `sendAudibleTab` atomically increments `seq` through the same controller by adding `enqueueNewTab(tab)`, so two audible callbacks cannot reuse a sequence or overwrite each other's outbox. Keep the 256-item extension outbox cap and generate every event ID with `crypto.randomUUID()`.

- [ ] **Step 8: Run extension GREEN suite and smoke import**

Run: `node --test ChromeExtension/service-worker.test.mjs && node -e "import('./ChromeExtension/service-worker.mjs')"`

Expected: all tests PASS and module import exits 0 without a Chrome global.

- [ ] **Step 9: Commit Task 8**

```bash
git add ChromeExtension/service-worker.mjs ChromeExtension/service-worker.test.mjs
git commit -m "fix: serialize Chrome observation outbox updates"
```

---

### Task 9: Bounded 5,000-event storage, generation clear barrier, and incremental App consumption

**Files:**
- Modify: `Sources/LidMuteCore/ObservationStore.swift`
- Modify: `Sources/LidMuteCore/EventStore.swift`
- Create: `Sources/LidMuteCore/ChromeInboxConsumer.swift`
- Modify: `Sources/LidMuteCore/Models.swift`
- Modify: `Package.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Modify: `Sources/LidMuteApp/ContentView.swift`
- Test: `Tests/LidMuteCoreTests/BoundedEventStoreTests.swift`
- Test: `Tests/LidMuteCoreTests/ChromeInboxConsumerTests.swift`
- Test: `Tests/LidMuteCoreTests/ObservationClearTests.swift`
- Test: `Tests/LidMuteCoreTests/AppViewModelObservationTests.swift`

**Interfaces:**
- Consumes: Task 7 `ObservationPaths`, shared `ObservationLocking`, generation-tagged `ChromeInboxRecord`, ordered dedup, and `ObservationStore.withExclusiveLock`; protection plan `AppLifecycleState` and `ApplicationLifecycleCoordinator.state` gate.
- Produces: `BoundedJSONLineEventStore(maximumCount: 5_000)`, `recent(limit:)`, `append(_:) -> EventStoreAppendResult`, and explicit `ObservationStorageHealth`.
- Produces: `ChromeInboxConsumer.consumeAvailable() -> ChromeConsumeBatch`, which returns only complete newline-terminated records and durably commits `{ generation, offset, remainder }` after event append.
- Produces: `ObservationStore.clearObservationData(inMemoryReset:) -> ObservationClearReport`, one generation-linearized clear operation preserving registration files.
- Produces: `AppViewModel` incremental event insertion and partial-clear-failure presentation without full-history reload per event.

- [ ] **Step 1: Write RED boundary tests for 0, 1, 4,999, 5,000, 5,001, and 10,000 valid events**

Create `Tests/LidMuteCoreTests/BoundedEventStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import LidMuteCore

private func event(_ sequence: UInt64) -> LidMuteEvent {
    LidMuteEvent(sequence: sequence, kind: .chromeTabAudible, detail: "event-\(sequence)")
}

@Test(arguments: [0, 1, 4_999, 5_000, 5_001, 10_000])
func storeRetainsNewestFiveThousandAcrossRestart(total: Int) throws {
    try withTemporaryDirectory { root in
        let url = root.appending(path: "events.jsonl")
        let store = BoundedJSONLineEventStore(url: url, maximumCount: 5_000)
        for value in 0..<total { _ = try store.append(event(UInt64(value))) }
        let reopened = BoundedJSONLineEventStore(url: url, maximumCount: 5_000)
        let recent = try reopened.recent(limit: 5_000)
        #expect(recent.count == min(total, 5_000))
        #expect(recent.first?.sequence == UInt64(max(0, total - 5_000)))
        #expect(recent.last?.sequence == (total == 0 ? nil : UInt64(total - 1)))
    }
}

@Test func corruptionIsReportedInsteadOfSilentlySkipped() throws {
    try withTemporaryDirectory { root in
        let url = root.appending(path: "events.jsonl")
        try Data("not-json\n".utf8).write(to: url)
        let store = BoundedJSONLineEventStore(url: url, maximumCount: 5_000)
        #expect(throws: EventStoreError.corruptRecord(line: 1)) { try store.recent(limit: 5_000) }
        #expect(store.health == .corruptRecord(line: 1))
    }
}
```

- [ ] **Step 2: Run bounded-store tests and verify RED**

Run: `swift test --filter BoundedEventStoreTests`

Expected: FAIL to compile because `BoundedJSONLineEventStore`, `EventStoreError`, and `ObservationStorageHealth` are undefined.

- [ ] **Step 3: Implement bounded append/rewrite and explicit health**

Replace `JSONLineEventStore` in `Sources/LidMuteCore/EventStore.swift` with:

```swift
public enum ObservationStorageHealth: Equatable, Sendable {
    case healthy
    case corruptRecord(line: Int)
    case permissionFailure
    case capacityFailure
    case ioFailure(String)
}

public enum EventStoreError: Error, Equatable {
    case corruptRecord(line: Int), permissionFailure, capacityFailure, ioFailure(String)
}

public struct EventStoreAppendResult: Sendable {
    public let appended: LidMuteEvent
    public let evictedCount: Int
}

public final class BoundedJSONLineEventStore: EventStoring, @unchecked Sendable {
    public private(set) var health: ObservationStorageHealth = .healthy
    public init(url: URL, maximumCount: Int = 5_000, fileSystem: ObservationFileSystem = POSIXObservationFileSystem(), lock: ObservationLocking = InProcessObservationLock())
    public func append(_ event: LidMuteEvent) throws
    @discardableResult public func appendReporting(_ event: LidMuteEvent) throws -> EventStoreAppendResult
    public func recent(limit: Int) throws -> [LidMuteEvent]
    public func clear() throws
}
```

`append(_:)` delegates to `appendReporting(_:)` and discards only the returned eviction count, preserving the protection plan's existing `EventStoring` interface. Inject the exact same `ObservationLocking` instance held by `ObservationStore`; the recursive production implementation prevents a nested consumer transaction from deadlocking while retaining one cross-process exclusion. On append, decode existing valid lines under that lock, append the new event, take `suffix(maximumCount)`, encode each record plus newline, atomically replace mode `0600`, sync the file and parent directory, and report evictions. A later optimization may rotate in chunks, but this task must first make disk count exact and crash-safe. Map `ENOSPC` to `.capacityFailure`, `EACCES`/`EPERM` to `.permissionFailure`, and malformed lines to `.corruptRecord(line:)`; never use `compactMap` to skip corruption.

- [ ] **Step 4: Run bounded-store tests and verify GREEN**

Run: `swift test --filter BoundedEventStoreTests`

Expected: all six boundaries and corruption health test PASS.

- [ ] **Step 5: Commit the bounded-store checkpoint**

```bash
git add Sources/LidMuteCore/EventStore.swift Sources/LidMuteCore/Models.swift Tests/LidMuteCoreTests/BoundedEventStoreTests.swift
git commit -m "feat: bound local event history to five thousand"
```

- [ ] **Step 6: Write RED incremental-consumer tests for half lines, restart replay, truncation, and inode replacement**

Create `Tests/LidMuteCoreTests/ChromeInboxConsumerTests.swift`:

```swift
import Foundation
import Testing
@testable import LidMuteCore

@Test func consumerDoesNotCommitHalfLine() throws {
    try withObservationFixture { fixture in
        let record = fixture.record(eventID: UUID(), generation: 0)
        let encoded = try JSONEncoder().encode(record) + Data([0x0A])
        try fixture.writeInbox(encoded.prefix(encoded.count - 3))
        let first = try fixture.consumer.consumeAvailable()
        #expect(first.records.isEmpty)
        #expect(first.committedOffset == 0)
        try fixture.appendInbox(encoded.suffix(3))
        let second = try fixture.consumer.consumeAvailable()
        #expect(second.records == [record])
        #expect(second.committedOffset == UInt64(encoded.count))
    }
}

@Test func crashAfterEventAppendReplaysWithoutTimelineDuplicate() throws {
    try withObservationFixture { fixture in
        let record = fixture.record(eventID: UUID(), generation: 0)
        try fixture.appendRecord(record)
        fixture.consumer.failBeforeCursorCommit = true
        #expect(throws: ChromeConsumeError.injectedCrash) { try fixture.consumer.consumeAvailable() }
        let restarted = fixture.makeConsumer()
        #expect(try restarted.consumeAvailable().records.isEmpty)
        #expect(try fixture.events.recent(limit: 10).count == 1)
    }
}

@Test func truncationOrReplacementResetsOffsetAndUsesEventIDIdempotency() throws {
    try withObservationFixture { fixture in
        let old = fixture.record(eventID: UUID(), generation: 0)
        try fixture.appendRecord(old)
        _ = try fixture.consumer.consumeAvailable()
        try fixture.replaceInbox(with: old, fixture.record(eventID: UUID(), generation: 0))
        let batch = try fixture.consumer.consumeAvailable()
        #expect(batch.records.count == 1)
        #expect(try fixture.events.recent(limit: 10).count == 2)
    }
}
```

The fixture's event store must enforce a persisted `observationEventID` idempotency key; add `public let observationEventID: UUID?` to `LidMuteEvent` with a default of `nil` for non-Chrome events.

- [ ] **Step 7: Run consumer tests and verify RED**

Run: `swift test --filter ChromeInboxConsumerTests`

Expected: FAIL to compile because `ChromeInboxConsumer`, `ChromeConsumeBatch`, cursor metadata, and `LidMuteEvent.observationEventID` do not exist.

- [ ] **Step 8: Implement complete-line incremental consumption with commit ordering**

Create `Sources/LidMuteCore/ChromeInboxConsumer.swift`:

```swift
public struct ChromeConsumeCursor: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let inode: UInt64
    public let offset: UInt64
    public let remainder: Data
}

public struct ChromeConsumeBatch: Sendable {
    public let records: [ChromeInboxRecord]
    public let committedOffset: UInt64
    public let health: ObservationStorageHealth
}

public final class ChromeInboxConsumer: @unchecked Sendable {
    public init(paths: ObservationPaths, observationStore: ObservationStore, eventStore: BoundedJSONLineEventStore)
    public func consumeAvailable() throws -> ChromeConsumeBatch
    public func resetInMemoryState()
}
```

Within `ObservationStore.withExclusiveLock`, read current generation and cursor, stat inbox inode and size, reset `{ offset: 0, remainder: empty }` if generation differs, size is below offset, or inode changed. Read only bytes from offset to EOF; combine with remainder; split only on byte `0x0A`; decode complete `ChromeInboxRecord`s; ignore records from older generations; append each event using `observationEventID` idempotency; only after all event appends succeed atomically write and sync the cursor containing the new committed byte offset and trailing remainder. If the process fails after event append but before cursor commit, replay is absorbed by the persisted event ID and the next successful run advances the cursor.

- [ ] **Step 9: Run consumer tests and verify GREEN**

Run: `swift test --filter ChromeInboxConsumerTests`

Expected: PASS; half-lines remain uncommitted, crash replay adds no duplicate, and truncation/replacement consumes only the new event.

- [ ] **Step 10: Write RED clear-barrier tests for concurrent accept/consume, full scope, preserved registration, and partial failure**

Create `Tests/LidMuteCoreTests/ObservationClearTests.swift`:

```swift
@Test func clearAdvancesGenerationAndOldAcceptedRecordCannotReappear() async throws {
    try await withObservationFixture { fixture in
        let old = try ChromeFrameDecoder().decode(validPayload())
        #expect(try fixture.observations.accept(old) == .accepted(eventID))
        let clear = try fixture.observations.clearObservationData {
            fixture.consumer.resetInMemoryState()
            fixture.memory.reset()
        }
        #expect(clear.oldGeneration == 0)
        #expect(clear.newGeneration == 1)
        #expect(try fixture.consumer.consumeAvailable().records.isEmpty)
        #expect(try fixture.events.recent(limit: 5_000).isEmpty)
        #expect(fixture.memory.events.isEmpty)
        #expect(fixture.memory.latestChromeEvidence == nil)
    }
}

@Test func clearPreservesRegistrationFiles() throws {
    try withObservationFixture { fixture in
        try fixture.writeRegistration(origin: "chrome-extension://abcdefghijklmnop/")
        _ = try fixture.observations.clearObservationData(inMemoryReset: {})
        #expect(try fixture.readOrigin() == "chrome-extension://abcdefghijklmnop/")
        #expect(fixture.manifestExists)
    }
}

@Test func partialClearFailureNamesUnclearedCategories() throws {
    try withObservationFixture { fixture in
        fixture.fileSystem.failRemovalFor = [fixture.paths.inbox]
        let report = try fixture.observations.clearObservationData(inMemoryReset: {})
        #expect(report.failures == [.inbox])
        #expect(report.isComplete == false)
    }
}

@Test func clearWaitsForAcceptAlreadyInsideOldGenerationAndThenRemovesIt() async throws {
    try await withObservationFixture { fixture in
        fixture.fileSystem.pauseAfterGenerationRead = true
        async let acceptance = fixture.observations.acceptAsync(try ChromeFrameDecoder().decode(validPayload()))
        await fixture.fileSystem.waitUntilPausedAfterGenerationRead()
        async let clear = fixture.observations.clearObservationDataAsync(inMemoryReset: {})
        #expect(await fixture.fileSystem.clearHasEnteredExclusiveSection == false)
        fixture.fileSystem.resumeAfterGenerationRead()
        #expect(try await acceptance == .accepted(eventID))
        let report = try await clear
        #expect(report.oldGeneration == 0 && report.newGeneration == 1)
        #expect(try fixture.consumer.consumeAvailable().records.isEmpty)
        #expect(fixture.fileSystem.operationOrder.containsSubsequence([
            "accept.read-generation:0", "accept.commit:0", "clear.lock", "clear.write-generation:1"
        ]))
    }
}

@Test func clearWaitsForConsumeBetweenEventAppendAndCursorCommit() async throws {
    try await withObservationFixture { fixture in
        _ = try fixture.observations.accept(ChromeFrameDecoder().decode(validPayload()))
        fixture.consumer.pauseAfterEventAppend = true
        async let consume = fixture.consumer.consumeAvailableAsync()
        await fixture.consumer.waitUntilPausedAfterEventAppend()
        async let clear = fixture.observations.clearObservationDataAsync {
            fixture.consumer.resetInMemoryState()
            fixture.memory.reset()
        }
        #expect(await fixture.fileSystem.clearHasEnteredExclusiveSection == false)
        fixture.consumer.resumeAfterEventAppend()
        _ = try await consume
        let report = try await clear
        #expect(report.newGeneration == 1)
        #expect(try fixture.events.recent(limit: 5_000).isEmpty)
        #expect(fixture.memory.events.isEmpty)
        #expect(try fixture.consumer.consumeAvailable().records.isEmpty)
    }
}
```

- [ ] **Step 11: Run clear tests and verify RED**

Run: `swift test --filter ObservationClearTests`

Expected: FAIL to compile because `clearObservationData`, `ObservationClearReport`, and `ObservationClearCategory` are undefined.

- [ ] **Step 12: Implement the monotonic generation clear barrier under the shared lock**

Extend `ObservationStore.swift` with:

```swift
public enum ObservationClearCategory: String, Codable, Equatable, Sendable {
    case events, inbox, deduplication, cursor, memory
}

public struct ObservationClearReport: Equatable, Sendable {
    public let oldGeneration: UInt64
    public let newGeneration: UInt64
    public let failures: [ObservationClearCategory]
    public var isComplete: Bool { failures.isEmpty }
}

extension ObservationStore {
    public func clearObservationData(inMemoryReset: () throws -> Void) throws -> ObservationClearReport
}
```

`clearObservationData` must acquire the same exclusive lock used by `accept` and `consumeAvailable`; atomically write and sync `oldGeneration + 1` first; truncate/sync `events` and `inbox`; remove dedup and cursor; invoke `inMemoryReset` before releasing the lock; collect category failures instead of claiming unconditional success. Because generation changes before deletion, a failed old-generation cleanup cannot later be consumed. Do not touch `chrome-origin.txt`, the Native Messaging manifest, extension ID, or registered executable path.

- [ ] **Step 13: Run clear-barrier tests and verify GREEN**

Run: `swift test --filter ObservationClearTests`

Expected: PASS for real accept/clear and consume/clear interleavings, generation increment, no old-data resurrection, registration preservation, and explicit partial failure categories. The controllable pauses must demonstrate that clear cannot enter its exclusive section until the in-flight old-generation transaction releases the shared lock.

- [ ] **Step 14: Add RED App tests for lifecycle gating, incremental UI append, and clear presentation**

First extend the existing standard test target in `Package.swift` so the App integration case can import the executable module without creating a second test entry point:

```swift
.testTarget(
    name: "LidMuteCoreTests",
    dependencies: ["LidMuteCore", "LidMuteApp"],
    path: "Tests/LidMuteCoreTests"
),
```

Then create `Tests/LidMuteCoreTests/AppViewModelObservationTests.swift`:

```swift
@MainActor @Test func chromeConsumptionWaitsForReadyLifecycle() throws {
    let harness = AppViewModelHarness(lifecycle: .recovering)
    harness.model.pollChromeInbox()
    #expect(harness.consumer.consumeCount == 0)
    harness.lifecycle.state = .ready
    harness.model.pollChromeInbox()
    #expect(harness.consumer.consumeCount == 1)
}

@MainActor @Test func eventCallbackAppendsWithoutReloadingHistory() throws {
    let harness = AppViewModelHarness(lifecycle: .ready)
    harness.store.recentCallCount = 0
    harness.coordinator.emit(event(7))
    #expect(harness.model.events.first?.sequence == 7)
    #expect(harness.store.recentCallCount == 0)
}

@MainActor @Test func clearRemovesAllChromePresentationButKeepsRegistration() async throws {
    let harness = AppViewModelHarness(lifecycle: .ready)
    harness.seedChromePresentation()
    await harness.model.clearObservationData()
    #expect(harness.model.events.isEmpty)
    #expect(harness.model.currentAudioSources.allSatisfy { !$0.isChromeTab })
    #expect(harness.model.chromeBridgeStatus == "等待 Chrome 扩展连接")
    #expect(harness.model.chromeExtensionId == harness.registeredExtensionID)
}
```

Define the test seam in `AppViewModel.swift` as `protocol LifecycleStateProviding: AnyObject { var state: AppLifecycleState { get } }` and conform `ApplicationLifecycleCoordinator` to it. The harness injects `LifecycleStateProviding`, `EventStoring`, `ChromeInboxConsuming`, and `ObservationClearing`; do not reach the user's real Application Support directory.

- [ ] **Step 15: Run App integration tests and verify RED**

Run: `swift test --filter AppViewModelObservationTests`

Expected: FAIL because `AppViewModel` still constructs concrete stores, starts the timer independent of lifecycle, reloads the entire log in `refresh()`, and exposes only `clearLog()`.

- [ ] **Step 16: Inject observation dependencies and make App updates incremental**

Modify `AppViewModel` initializer to accept exact protocols with production defaults:

```swift
@MainActor
init(
    coordinator: ProtectionCoordinator,
    eventStore: BoundedJSONLineEventStore,
    inboxConsumer: ChromeInboxConsumer,
    observationStore: ObservationStore,
    lifecycle: LifecycleStateProviding
)
```

At startup call `eventStore.recent(limit: 5_000)` once and reverse for newest-first UI. Change `coordinator.onEvent` to insert the event at index zero and remove the last item only when count exceeds 5,000; do not call `recent` from general `refresh()`. Rename the timer callback to internal `pollChromeInbox()` and guard `lifecycle.state == .ready`. For each consumed record, update `latestChromeEvidence` and presentation only after the consumer has durably appended its timeline event. Replace `clearLog()` with async `clearObservationData()`, pass an in-memory reset closure clearing `events`, `latestChromeEvidence`, recent-event timestamp, current Chrome tab source, consumer remainder, and connection presentation; retain `chromeExtensionId` and registration status. Publish partial failures as `storageStatusText = "部分数据未清空：\(report.failures.map(\.rawValue).joined(separator: "、"))"`.

- [ ] **Step 17: Update the Clear button to show progress and partial failure rather than unconditional success**

In `ContentView.swift`, call the async operation and prevent overlapping clears:

```swift
Button {
    Task { await model.clearObservationData() }
} label: {
    Label(model.isClearingObservationData ? "正在清空" : "清空", systemImage: "trash")
}
.disabled(model.isClearingObservationData)
```

Render `model.storageStatusText` under the timeline header when non-empty. Do not alter the Chrome guide, registered ID, or Native Messaging manifest.

- [ ] **Step 18: Run App and all Task 9 tests and verify GREEN**

Run: `swift test --filter BoundedEventStoreTests && swift test --filter ChromeInboxConsumerTests && swift test --filter ObservationClearTests && swift test --filter AppViewModelObservationTests`

Expected: PASS; App tests show one startup history query, zero history query per callback, lifecycle-gated consumption, and complete in-memory clear without unregistering Chrome.

- [ ] **Step 19: Run the complete regression suite and inspect persisted privacy/caps**

Run: `swift test && node --test ChromeExtension/service-worker.test.mjs && bash Scripts/check-visual-principles.sh`

Expected: all Swift and Node tests PASS and visual checks print `PASS visual principle source checks`.

Run: `rg -n "compactMap.*JSONDecoder|Data\(contentsOf: inboxURL\)|events = .*store\.load|sorted\(\).*suffix\(4_096\)" Sources`

Expected: no matches; corruption is explicit, inbox reads are incremental, event callbacks do not reload history, and dedup uses acceptance order.

- [ ] **Step 20: Commit Task 9**

```bash
git add Package.swift Sources/LidMuteCore/ObservationStore.swift Sources/LidMuteCore/EventStore.swift Sources/LidMuteCore/ChromeInboxConsumer.swift Sources/LidMuteCore/Models.swift Sources/LidMuteApp/AppViewModel.swift Sources/LidMuteApp/ContentView.swift Tests/LidMuteCoreTests/BoundedEventStoreTests.swift Tests/LidMuteCoreTests/ChromeInboxConsumerTests.swift Tests/LidMuteCoreTests/ObservationClearTests.swift Tests/LidMuteCoreTests/AppViewModelObservationTests.swift
git commit -m "feat: bound and atomically clear observation history"
```

---

## Plan Self-Review

- **Spec coverage:** Task 7 covers complete frame parsing, exact validation limits, incognito zero persistence, durable ACK, ordered 4,096-ID deduplication, duplicate acceptance, and retryable failures. Task 8 covers serialized enqueue/ACK/flush, all dispositions, duplicate/out-of-order ACKs, and reconnect replay. Task 9 covers exact 5,000 disk cap, corruption health, partial-line/replacement consumption, event-ID idempotency, generation clear barrier, complete clear scope, preserved registration, lifecycle gating, and incremental UI updates.
- **Dependency check:** The plan explicitly requires the protection plan's standard `LidMuteCoreTests` `.testTarget`, `AppLifecycleState`, and `ApplicationLifecycleCoordinator.state` gate before Task 7/Task 9 execution.
- **Type consistency:** Task 7 produces `ObservationPaths`, `ObservationStore`, `ChromeInboxRecord`, and `ChromeAcceptDisposition`; Tasks 8 and 9 consume those exact names. Task 9 uses one `ObservationStorageHealth` type across store, consumer, and App presentation.
- **Privacy check:** Incognito frames are classified only after bounded schema validation and return before evidence serialization, dedup persistence, or logging; normal URLs remain complete by product decision.
- **Placeholder scan:** No TBD, TODO, “implement later,” “similar to,” or generic error-handling/test placeholders remain; every RED/GREEN step includes an exact command and expected result.
