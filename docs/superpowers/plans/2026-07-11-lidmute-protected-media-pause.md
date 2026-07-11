# LidMute Protected Media Pause Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Request a macOS system media pause when protected lid, simulated-lid, or night-display-sleep states have reliable Chrome audio evidence, without adding webpage permissions or resuming playback afterward.

**Architecture:** `ProtectionCoordinator` remains the pure decision owner and emits a typed `MediaPauseRequest` through a callback after checking protection state, Chrome evidence, one-shot activation, and a three-second global debounce. `AppViewModel` consumes the request, sends the existing `.playPause` system media key, and reports success or failure back to Core for durable, accurately worded events. Built-in-speaker muting remains independent and authoritative.

**Tech Stack:** Swift 6, macOS 15+, SwiftUI, AppKit/CoreGraphics system media events, CoreAudio process evidence, Chrome Manifest V3 Native Messaging, executable Swift behavior tests, Node test runner.

## Global Constraints

- Trigger sources are real lid close, simulated lid close, and active night display-sleep protection.
- Never send a media key while the guard is disabled or no protection source is active.
- Never send a media key without active Chrome process evidence or a fresh Chrome `audible: true` event.
- Use a global three-second debounce and do not react repeatedly to identical CoreAudio polling snapshots.
- Do not send any media command when protection ends, the lid opens, the display wakes, or the guard is disabled.
- Do not add `scripting`, `<all_urls>`, content scripts, or webpage DOM access to the Chrome extension.
- Log “system pause request sent/failed”; never claim that a webpage or Chrome was successfully paused.
- Speaker silence and restoration behavior must remain unchanged if media dispatch fails.

---

### Task 1: Typed Pause Requests And Event Presentation

**Files:**
- Modify: `Sources/LidMuteCore/Models.swift`
- Modify: `Sources/LidMuteCore/EventPresentation.swift`
- Modify: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Consumes: existing `ProtectionSource`, `AudioProcess`, `ChromeTabEvidence`, and `CorrelationStatus`.
- Produces: `MediaPauseTrigger`, `MediaPauseRequest`, `.mediaPauseRequested`, and `.mediaPauseRequestFailed` for later coordinator and App tasks.

- [ ] **Step 1: Write the failing request-model and presentation test**

Add the test call before the existing success prints in `main()`:

```swift
try mediaPauseRequestRetainsEvidenceAndReadablePresentation()
```

Add this test beside `mediaCommandsUseSystemKeyTypes()`:

```swift
private static func mediaPauseRequestRetainsEvidenceAndReadablePresentation() throws {
    let process = activeProcess(pid: 1357)
    let request = MediaPauseRequest(
        trigger: .lidProtectionStarted,
        source: .lid,
        process: process,
        chromeTab: nil,
        correlation: .systemMatched
    )
    let sent = EventPresentation(kind: .mediaPauseRequested)
    let failed = EventPresentation(kind: .mediaPauseRequestFailed)

    guard request.source == .lid,
          request.process == process,
          sent.title == "已请求系统暂停",
          sent.symbolName == "pause.circle.fill",
          failed.title == "系统暂停请求失败" else {
        throw BehaviorTestError.expectationFailed("media pause request model or presentation lost evidence")
    }
}
```

Add a matching PASS line:

```swift
print("PASS media pause requests retain evidence and readable presentation")
```

- [ ] **Step 2: Run the behavior executable and verify RED**

Run:

```zsh
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteCoreBehaviorTests
```

Expected: compilation fails because `MediaPauseRequest`, `MediaPauseTrigger`, and the two event kinds do not exist.

- [ ] **Step 3: Add the minimal request and event types**

Add to `Models.swift` after `MediaCommand`:

```swift
public enum MediaPauseTrigger: String, Codable, Sendable {
    case lidProtectionStarted
    case simulatedLidProtectionStarted
    case nightProtectionStarted
    case chromeAudioStarted
}

public struct MediaPauseRequest: Equatable, Sendable {
    public let id: UUID
    public let trigger: MediaPauseTrigger
    public let source: ProtectionSource?
    public let process: AudioProcess?
    public let chromeTab: ChromeTabEvidence?
    public let correlation: CorrelationStatus

    public init(
        id: UUID = UUID(),
        trigger: MediaPauseTrigger,
        source: ProtectionSource?,
        process: AudioProcess?,
        chromeTab: ChromeTabEvidence?,
        correlation: CorrelationStatus
    ) {
        self.id = id
        self.trigger = trigger
        self.source = source
        self.process = process
        self.chromeTab = chromeTab
        self.correlation = correlation
    }
}
```

Add to `LidMuteEventKind`:

```swift
case mediaPauseRequested
case mediaPauseRequestFailed
```

Map them in `EventPresentation.init(kind:)`:

```swift
case .mediaPauseRequested:
    (title, symbolName) = ("已请求系统暂停", "pause.circle.fill")
case .mediaPauseRequestFailed:
    (title, symbolName) = ("系统暂停请求失败", "exclamationmark.circle.fill")
```

- [ ] **Step 4: Run the behavior executable and verify GREEN**

Run:

```zsh
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteCoreBehaviorTests
```

Expected: all existing tests plus `PASS media pause requests retain evidence and readable presentation` pass.

- [ ] **Step 5: Commit the typed contract**

```zsh
git add Sources/LidMuteCore/Models.swift Sources/LidMuteCore/EventPresentation.swift Tests/LidMuteCoreBehavior/main.swift
git commit -m "feat: add protected media pause request types"
```

---

### Task 2: Protection-State Decision And Debounce

**Files:**
- Modify: `Sources/LidMuteCore/ProtectionCoordinator.swift`
- Modify: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Consumes: `MediaPauseRequest` and `MediaPauseTrigger` from Task 1, `AudioControlling.activeOutputProcesses()`, and existing protection sources.
- Produces: `ProtectionCoordinator.onMediaPauseRequest: ((MediaPauseRequest) -> Void)?`, deterministic `now` injection, process/event evidence checks, and three-second request debounce.

- [ ] **Step 1: Make the fake audio source configurable**

Change `FakeAudioController` so tests can provide the current CoreAudio snapshot:

```swift
var activeProcesses: [AudioProcess] = []

func activeOutputProcesses() throws -> [AudioProcess] { activeProcesses }
```

- [ ] **Step 2: Write failing tests for protection entry, missing evidence, and exits**

Add these calls in `main()`:

```swift
try protectedSourcesRequestPauseOnlyWithChromeEvidence()
try protectionExitNeverRequestsMediaPlayback()
```

Add:

```swift
@MainActor
private static func protectedSourcesRequestPauseOnlyWithChromeEvidence() throws {
    let cases: [(MediaPauseTrigger, ProtectionSource, @MainActor (ProtectionCoordinator) -> Void)] = [
        (.lidProtectionStarted, .lid, { $0.receiveLidState(closed: true) }),
        (.simulatedLidProtectionStarted, .lid, { $0.receiveLidState(closed: true, simulated: true) }),
        (.nightProtectionStarted, .night, { $0.receiveNightProtection(true) }),
    ]

    for (expectedTrigger, source, activate) in cases {
        let audio = FakeAudioController()
        audio.activeProcesses = [activeProcess(pid: 1357)]
        let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
        var requests: [MediaPauseRequest] = []
        coordinator.onMediaPauseRequest = { requests.append($0) }

        coordinator.setEnabled(true)
        activate(coordinator)

        guard requests.count == 1,
              requests[0].trigger == expectedTrigger,
              requests[0].source == source,
              requests[0].process?.bundleID == "com.google.Chrome" else {
            throw BehaviorTestError.expectationFailed("protected source did not request one evidence-backed pause")
        }
    }

    let silentAudio = FakeAudioController()
    let silentCoordinator = ProtectionCoordinator(audio: silentAudio, store: MemoryEventStore())
    var silentRequests = 0
    silentCoordinator.onMediaPauseRequest = { _ in silentRequests += 1 }
    silentCoordinator.setEnabled(true)
    silentCoordinator.receiveLidState(closed: true)
    guard silentRequests == 0 else {
        throw BehaviorTestError.expectationFailed("protection requested pause without Chrome audio evidence")
    }
}

@MainActor
private static func protectionExitNeverRequestsMediaPlayback() throws {
    let audio = FakeAudioController()
    audio.activeProcesses = [activeProcess(pid: 1357)]
    let coordinator = ProtectionCoordinator(audio: audio, store: MemoryEventStore())
    var requestCount = 0
    coordinator.onMediaPauseRequest = { _ in requestCount += 1 }

    coordinator.setEnabled(true)
    coordinator.receiveLidState(closed: true)
    let countWhileProtected = requestCount
    coordinator.receiveLidState(closed: false)
    coordinator.setEnabled(false)

    guard requestCount == countWhileProtected else {
        throw BehaviorTestError.expectationFailed("protection exit sent a media command")
    }
}
```

- [ ] **Step 3: Run the tests and verify RED**

Run:

```zsh
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteCoreBehaviorTests
```

Expected: compilation fails because `onMediaPauseRequest` is missing.

- [ ] **Step 4: Add coordinator request state and deterministic time**

Add to `ProtectionCoordinator`:

```swift
public var onMediaPauseRequest: ((MediaPauseRequest) -> Void)?

private let now: () -> Date
private let mediaPauseDebounce: TimeInterval
private var lastMediaPauseRequestAt: Date?

public init(
    audio: AudioControlling,
    store: EventStoring,
    mediaPauseDebounce: TimeInterval = 3,
    now: @escaping () -> Date = Date.init
) {
    self.audio = audio
    self.store = store
    self.mediaPauseDebounce = mediaPauseDebounce
    self.now = now
}
```

Replace the existing initializer rather than adding an overload.

Add helpers:

```swift
private func activeChromeProcess(in processes: [AudioProcess]) -> AudioProcess? {
    processes.first {
        $0.isOutputActive &&
        ($0.bundleID?.localizedCaseInsensitiveContains("chrome") == true ||
         $0.name.localizedCaseInsensitiveContains("chrome"))
    }
}

private func requestPauseForActiveChrome(source: ProtectionSource, trigger: MediaPauseTrigger) {
    guard isEnabled, state == .protecting,
          let processes = try? audio.activeOutputProcesses(),
          let process = activeChromeProcess(in: processes) else { return }
    emitMediaPauseRequest(
        trigger: trigger,
        source: source,
        process: process,
        chromeTab: nil,
        correlation: .systemMatched
    )
}

private func emitMediaPauseRequest(
    trigger: MediaPauseTrigger,
    source: ProtectionSource?,
    process: AudioProcess?,
    chromeTab: ChromeTabEvidence?,
    correlation: CorrelationStatus
) {
    let timestamp = now()
    if let lastMediaPauseRequestAt,
       timestamp.timeIntervalSince(lastMediaPauseRequestAt) < mediaPauseDebounce { return }
    lastMediaPauseRequestAt = timestamp
    onMediaPauseRequest?(
        MediaPauseRequest(
            trigger: trigger,
            source: source,
            process: process,
            chromeTab: chromeTab,
            correlation: correlation
        )
    )
}
```

After `updateProtectionSource(.lid, active: true)` in the close path, call:

```swift
requestPauseForActiveChrome(
    source: .lid,
    trigger: simulated ? .simulatedLidProtectionStarted : .lidProtectionStarted
)
```

After `updateProtectionSource(.night, active: true)` in `receiveNightProtection`, call:

```swift
if active {
    requestPauseForActiveChrome(source: .night, trigger: .nightProtectionStarted)
}
```

Reset `lastMediaPauseRequestAt` when disabling the guard and whenever the final active protection source ends.

- [ ] **Step 5: Run the tests and verify protection-entry GREEN**

Run:

```zsh
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteCoreBehaviorTests
```

Expected: both new protection-source tests pass and all previous behavior remains green.

- [ ] **Step 6: Write the failing Chrome-event and debounce test**

Add the call:

```swift
try chromePauseRequestsUseGlobalDebounce()
```

Add:

```swift
@MainActor
private static func chromePauseRequestsUseGlobalDebounce() throws {
    var clock = Date(timeIntervalSince1970: 1_000)
    let audio = FakeAudioController()
    let coordinator = ProtectionCoordinator(
        audio: audio,
        store: MemoryEventStore(),
        mediaPauseDebounce: 3,
        now: { clock }
    )
    var requests: [MediaPauseRequest] = []
    coordinator.onMediaPauseRequest = { requests.append($0) }
    let evidence = ChromeTabEvidence(
        sessionID: "s", windowID: 1, tabID: 2, index: 0,
        title: "优酷", url: "https://v.youku.com", audible: true,
        muted: false, isActive: true, isPinned: false, isIncognito: false
    )

    coordinator.setEnabled(true)
    coordinator.receiveLidState(closed: true)
    coordinator.receiveChromeEvidence(evidence)
    coordinator.receiveChromeEvidence(evidence)
    guard requests.count == 1 else {
        throw BehaviorTestError.expectationFailed("Chrome pause request ignored debounce")
    }

    clock = clock.addingTimeInterval(3.1)
    coordinator.receiveChromeEvidence(evidence)
    guard requests.count == 2,
          requests[1].trigger == .chromeAudioStarted,
          requests[1].chromeTab == evidence else {
        throw BehaviorTestError.expectationFailed("fresh Chrome event did not request pause after debounce")
    }
}
```

- [ ] **Step 7: Run the test and verify RED**

Expected: the Chrome event records evidence but does not emit a pause request.

- [ ] **Step 8: Emit requests from fresh Chrome and CoreAudio activity**

In `receiveChromeEvidence`, after enforcing speaker silence when applicable, add:

```swift
if isEnabled, state == .protecting, evidence.audible {
    emitMediaPauseRequest(
        trigger: .chromeAudioStarted,
        source: nil,
        process: chromeProcess,
        chromeTab: evidence,
        correlation: correlation
    )
}
```

In `receiveAudioSnapshot`, find newly active Chrome processes and request once per newly active process; the global debounce collapses simultaneous process/tab evidence:

```swift
for process in newlyActive where activeChromeProcess(in: [process]) != nil {
    emitMediaPauseRequest(
        trigger: .chromeAudioStarted,
        source: nil,
        process: process,
        chromeTab: nil,
        correlation: .systemMatched
    )
}
```

- [ ] **Step 9: Run the complete behavior executable and commit**

Expected: all tests pass, including evidence gating, exits, and debounce.

```zsh
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteCoreBehaviorTests
git add Sources/LidMuteCore/ProtectionCoordinator.swift Tests/LidMuteCoreBehavior/main.swift
git commit -m "feat: request media pause during protected Chrome audio"
```

---

### Task 3: Dispatch System Media Key And Persist Honest Results

**Files:**
- Modify: `Sources/LidMuteCore/ProtectionCoordinator.swift`
- Modify: `Sources/LidMuteApp/AppViewModel.swift`
- Modify: `Tests/LidMuteCoreBehavior/main.swift`

**Interfaces:**
- Consumes: `ProtectionCoordinator.onMediaPauseRequest`, `MediaPauseRequest`, and `SystemMediaController.send(.playPause)`.
- Produces: `ProtectionCoordinator.recordMediaPauseResult(_:errorDescription:)`, durable success/failure events, and user-facing `mediaStatus` text.

- [ ] **Step 1: Write the failing result-logging test**

Add the call:

```swift
try mediaPauseResultsUseHonestEventWording()
```

Add:

```swift
@MainActor
private static func mediaPauseResultsUseHonestEventWording() throws {
    let store = MemoryEventStore()
    let coordinator = ProtectionCoordinator(audio: FakeAudioController(), store: store)
    let request = MediaPauseRequest(
        trigger: .lidProtectionStarted,
        source: .lid,
        process: activeProcess(pid: 1357),
        chromeTab: nil,
        correlation: .systemMatched
    )

    coordinator.recordMediaPauseResult(request, errorDescription: nil)
    coordinator.recordMediaPauseResult(request, errorDescription: "event failed")

    guard store.events.count == 2,
          store.events[0].kind == .mediaPauseRequested,
          store.events[0].detail.contains("已发送系统暂停请求"),
          !store.events[0].detail.contains("网页已暂停"),
          store.events[1].kind == .mediaPauseRequestFailed,
          store.events[1].detail.contains("event failed") else {
        throw BehaviorTestError.expectationFailed("media pause result log overclaimed or lost failure details")
    }
}
```

- [ ] **Step 2: Run the behavior executable and verify RED**

Expected: compilation fails because `recordMediaPauseResult` is missing.

- [ ] **Step 3: Implement durable result events**

Add this public method to `ProtectionCoordinator`:

```swift
public func recordMediaPauseResult(_ request: MediaPauseRequest, errorDescription: String?) {
    let sourceDetail: String
    switch request.trigger {
    case .lidProtectionStarted: sourceDetail = "真实合盖保护"
    case .simulatedLidProtectionStarted: sourceDetail = "模拟合盖保护"
    case .nightProtectionStarted: sourceDetail = "夜间息屏保护"
    case .chromeAudioStarted: sourceDetail = "保护期间 Chrome 再次发声"
    }

    if let errorDescription {
        record(
            .mediaPauseRequestFailed,
            "\(sourceDetail)：系统暂停请求失败：\(errorDescription)",
            process: request.process,
            chromeTab: request.chromeTab,
            correlation: request.correlation
        )
    } else {
        record(
            .mediaPauseRequested,
            "\(sourceDetail)：已发送系统暂停请求",
            process: request.process,
            chromeTab: request.chromeTab,
            correlation: request.correlation
        )
    }
}
```

- [ ] **Step 4: Run the behavior executable and verify GREEN**

Expected: the new result test passes and no event says the webpage definitely paused.

- [ ] **Step 5: Connect AppViewModel to the existing media controller**

In `AppViewModel.init()`, install the request handler before `refresh()`:

```swift
coordinator.onMediaPauseRequest = { [weak self] request in
    self?.handleMediaPauseRequest(request)
}
```

Add:

```swift
private func handleMediaPauseRequest(_ request: MediaPauseRequest) {
    do {
        try mediaController.send(.playPause)
        mediaStatus = "已请求系统暂停"
        coordinator.recordMediaPauseResult(request, errorDescription: nil)
    } catch {
        mediaStatus = "系统暂停请求失败：\(error.localizedDescription)"
        coordinator.recordMediaPauseResult(request, errorDescription: error.localizedDescription)
    }
}
```

Do not call this handler from protection-exit paths and do not modify `sendMediaCommand(_:)`, which remains the manual previous/play-pause/next control.

- [ ] **Step 6: Build the app and run all behavior tests**

Run:

```zsh
swift build --disable-sandbox --scratch-path /tmp/lidmute-build
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteCoreBehaviorTests
```

Expected: `LidMuteApp`, `LidMuteCore`, and `LidMuteNativeHost` compile; all behavior tests pass.

- [ ] **Step 7: Commit App dispatch and result logging**

```zsh
git add Sources/LidMuteCore/ProtectionCoordinator.swift Sources/LidMuteApp/AppViewModel.swift Tests/LidMuteCoreBehavior/main.swift
git commit -m "feat: dispatch protected system pause requests"
```

---

### Task 4: Documentation, Permission Guard, And End-To-End Verification

**Files:**
- Modify: `docs/LidMute-中文设计说明.md`
- Verify: `ChromeExtension/manifest.json`
- Verify: `Scripts/run-smoke-check.sh`

**Interfaces:**
- Consumes: completed protected-pause behavior and current smoke-check pipeline.
- Produces: accurate Chinese operator documentation and final verification evidence without expanding Chrome permissions.

- [ ] **Step 1: Update the Chinese behavior documentation**

In `docs/LidMute-中文设计说明.md`, replace the statement that LidMute never tries to pause video with:

```markdown
保护期间如果 CoreAudio 检测到 Chrome 正在输出音频，或 Chrome 扩展上报新的发声标签页，LidMute 会发送一次 macOS 系统播放/暂停媒体键。该按键由 macOS 选择接收媒体会话，因此日志只记录“已发送系统暂停请求”，不声称网页已成功暂停。内建扬声器静音始终作为最终保障；开盖、亮屏、夜间策略结束或关闭守卫不会自动恢复网页播放。
```

Add these exact acceptance items under `## 八、测试与验收`:

```markdown
10. Chrome 正在发声时分别触发真实合盖、模拟合盖和夜间息屏保护，确认每次保护周期最多发送一次系统暂停请求。
11. 在 3 秒内连续产生多个 Chrome 发声证据，确认只记录一次系统暂停请求；3 秒后新的发声事件可产生新请求。
12. 模拟系统媒体键发送失败，确认错误被记录且内建扬声器继续保持静音。
13. 开盖、模拟开盖、亮屏、夜间时段结束和关闭守卫后，确认 LidMute 不自动恢复网页播放。
```

- [ ] **Step 2: Add an explicit permission regression assertion to the smoke script**

After checking `ChromeExtension/manifest.json`, add:

```zsh
! grep -q '"scripting"' ChromeExtension/manifest.json
! grep -q '"<all_urls>"' ChromeExtension/manifest.json
```

This turns the no-page-access decision into an automated regression check.

- [ ] **Step 3: Run the complete smoke check**

Run:

```zsh
zsh Scripts/run-smoke-check.sh
```

Expected:

- all Swift behavior tests pass;
- both Chrome extension Node tests pass;
- app and Native Host build;
- two consecutive app bundles succeed;
- icon and bundle checks pass;
- permission regression checks pass;
- final line is `PASS LidMute smoke check`.

- [ ] **Step 4: Perform manual integration verification without overclaiming**

1. Launch `dist/LidMute.app` and keep the registered Chrome extension enabled.
2. Start a Chrome video, enable the guard, and click **模拟合盖**.
3. Confirm the built-in speaker is muted and the timeline records **已请求系统暂停** once.
4. Confirm a supporting player pauses; click **模拟开盖** and verify it remains paused.
5. Repeat using an active night display-sleep condition and confirm no automatic resume when the condition ends.
6. Trigger two Chrome audible events inside three seconds and confirm only one system pause request is recorded.
7. Confirm the timeline still records full Chrome title and URL evidence.

- [ ] **Step 5: Check the final diff and commit documentation/verification**

```zsh
git diff --check
git status --short
git add docs/LidMute-中文设计说明.md Scripts/run-smoke-check.sh
git commit -m "docs: verify protected media pause behavior"
```

Expected: only the planned documentation and smoke-check changes remain before the commit; the worktree is clean afterward.
