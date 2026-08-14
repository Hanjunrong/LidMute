# Task 10 Implementation Report

## Result

Implemented typed runtime health, monotonic Native Host heartbeat, moved-bundle manifest inspection/repair, and a closed privacy-safe diagnostic event surface. The implementation preserves the existing speaker mutation seam, Chrome observation persistence semantics, observation-clear safety sequencing, full normal-tab URLs, and `VisualLayoutMetrics.cardSpacing = 0`.

## RED / GREEN evidence

All Swift commands used isolated `/tmp` module caches and `--disable-sandbox` after the first ordinary SwiftPM invocation demonstrated the environment's nested cache sandbox failure.

1. Typed health
   - RED: `swift test --filter HealthStatusTests` first failed before compilation because the default Clang module cache was not writable. Re-run with isolated caches: `swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-red1-build --filter HealthStatusTests` exited 1 with `cannot find 'CoreAudioHealth' in scope` and `cannot find 'AppHealthSnapshot' in scope`.
   - GREEN: the same isolated command passed 3/3 tests.
2. Heartbeat schema, freshness, permissions, and lifecycle
   - RED: isolated `swift test ... --filter ChromeHostHeartbeatTests` exited 1 with missing `FileChromeHostHeartbeatStore` and `ChromeHostHeartbeatWriter`.
   - GREEN: the focused command passed 5 test functions, including both parameterized impossible-uptime cases, exact 6-second TTL, `0600`/`0700`, malformed schema, synchronous first write, repeated removal, and session-safe cleanup.
3. Native Host source contract
   - RED: after adding the two smoke assertions, `zsh Scripts/run-smoke-check.sh` exited 1 at the missing `heartbeatInterval: 2` / cleanup contract after the pre-existing Swift and Node tests had passed.
   - GREEN: after starting the writer after origin authentication and installing `defer { heartbeatWriter.stopAndRemove() }`, heartbeat tests and both source assertions exited 0; the final complete smoke run also exited 0.
4. Manifest mismatch and safe repair
   - RED: isolated `swift test ... --filter ChromeHostRegistrationTests` exited 1 because `ChromeHostRegistration` and `ChromeHostRegistrationError` did not exist.
   - GREEN: the focused command passed 3/3 tests covering standardized moved-path detection, origin/manifest-field preservation, private permissions, invalid registered IDs, and non-executable expected hosts.
5. Privacy-safe diagnostics
   - RED: isolated `swift test ... --filter LidMuteDiagnosticsTests` exited 1 because `LidMuteDiagnosticEvent` and `LidMuteDiagnosticSinking` did not exist.
   - GREEN: the focused command passed 2/2 tests. The only sink API accepts the closed no-payload enum.
6. App health integration
   - RED: isolated `swift test ... --filter AppViewModelHealthTests` exited 1 for missing typed audio polling, injected health dependencies, health publication, and mappers.
   - Intermediate RED: the first compiled implementation produced 3 expectation failures because injected lifecycle readiness was not projected into `AppViewModel.lifecycleState`; this also proved the CoreAudio failure tests were behavior-sensitive.
   - GREEN: after initializing the published lifecycle state from the injected provider, the initial 7/7 test functions passed, including 12 parameterized total-mapper cases, stale heartbeat, repair, distinct lid failures, CoreAudio failure/no-data separation, and preservation of the last audio snapshot.
7. Independent-review hardening
   - Review found that the original token comparison followed by file removal was process-local and therefore allowed a second Native Host to replace the heartbeat between those operations. Review also found drift from the authoritative stable interface (`ChromeBridgeHealth` identity payloads, immutable `AppHealthSnapshot`, and `@MainActor ChromeHostRegistering`) and that recent acceptance needed both session identity and an expiry.
   - RED: the new interface tests first failed to compile because `.connected` had no associated session token/PID. The deterministic interleaving test also failed to compile because the store had no conditional-remove hook or `remove(ifSessionToken:)` operation.
   - GREEN: a sibling `0600` lock file plus `Darwin.lockf` now serializes cross-process compare/remove and refresh/write operations; the interleaving test passes without allowing an older session to delete a replacement. The exact stable health interfaces are restored, fresh heartbeat identity is carried through connected/recently-accepted states, acceptance from a different session cannot claim the current host, recent acceptance expires after 30 seconds, and Chrome degradation diagnostics emit only on typed state transitions.
8. Durable acceptance provenance follow-up
   - The final approval pass found that the first review fix still inferred acceptance provenance from the heartbeat identity observed before and after App-side inbox polling. A record durably accepted by Host A but consumed while Host B remained fresh could therefore be mislabeled `.recentlyAccepted` for Host B because `ChromeInboxRecord` intentionally contains no Host identity.
   - RED: `oldSessionBacklogCannotClaimTheCurrentHostIdentity` compiled and failed behaviorally: after consuming an old backlog record, the model published `.recentlyAccepted` with the current Host B token/PID instead of `.connected`. After removing the polling-time inference, this regression passed. A second RED then failed to compile on the deliberately missing `ChromeHostAcceptance`, `ChromeHostAcceptancePersisting`, `FileChromeHostAcceptanceStore`, `acceptanceStore:` injection, and `NativeHostSession.onAccepted` callback.
   - GREEN: `NativeHostSession` now invokes a non-sensitive callback only after a new `.accepted` disposition returns from the already-durable ObservationStore boundary. The Native Host writes a separate atomic `0600` acceptance sidecar containing only schema version, session token, PID, and monotonic uptime. The sidecar write shares the heartbeat lock and is rejected unless its token/PID still match the current heartbeat, so an old Host cannot overwrite current provenance. The App reports `.recentlyAccepted` only when that marker exactly matches the fresh heartbeat and is at most 30 seconds old. Duplicate and incognito dispositions do not write the marker; the inbox record, ACK, deduplication, cursor, pending-delivery, and clear persistence formats remain unchanged.

## Implementation summary

- Added public Core health value types and priority/termination policy.
- Added private atomic heartbeat persistence with schema version 1, monotonic uptime-only freshness, 6-second TTL, immediate write plus 2-second serial timer, and a cross-process lock around token-checked refresh/removal so an older Host cannot overwrite or remove a newer heartbeat.
- Replaced PID liveness inference in the app with heartbeat freshness; connected and recently accepted health retain the fresh Host's session token/PID. A separate acceptance marker is written at the Native Host's durable `.accepted` boundary and is projected as recent only for the exact current session and for at most 30 seconds; App-side backlog consumption never invents provenance.
- Added typed CoreAudio and lid-monitor outcomes. CoreAudio query failure retains the last process snapshot and never masquerades as no active output.
- Added total mappings for all stable `ObservationStorageHealth` and `SpeakerRecoveryOutcome` cases without changing their persistence semantics.
- Added manifest inspection and one-click repair that retains the registered legal origin and existing fixed manifest fields, changes only the standardized host path, atomically writes JSON, and applies `0600`.
- Added fixed-copy ContentView presentation for CoreAudio no-data/failure, manifest old/new paths and repair, and critical unknown recovery safety. Existing card metrics and modifier ordering remain intact.
- Added a closed diagnostic enum and OSLog adapter. No diagnostic method accepts arbitrary strings, errors, raw data, tab evidence, titles, URLs, or frames.

## Final verification

- Focused post-review sequence on `/tmp/lidmute-task10-provenance-green-build`:
  - `HealthStatusTests`: 4 passed, 0 failed.
  - `ChromeHostHeartbeatTests`: 7 functions passed (8 executions including parameterization), 0 failed, including deterministic replacement-during-removal and acceptance-marker session binding.
  - `ChromeNativeMessagingTests`: 16 passed, 0 failed, including accepted-only callback coverage.
  - `ChromeHostRegistrationTests`: 3 passed, 0 failed.
  - `LidMuteDiagnosticsTests`: 2 passed, 0 failed.
  - `AppViewModelHealthTests`: 11 functions passed (23 executions including parameterization), 0 failed, including cross-Host backlog attribution.
- Full `swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-provenance-green-build`: 125 XCTest + 74 Swift Testing executions = 199 passed, 0 failed.
- `bash Scripts/check-visual-principles.sh`: `PASS visual principle source checks`. (A prior `zsh` invocation correctly failed because this script relies on Bash's `BASH_SOURCE`; the required Bash invocation passed.)
- `LIDMUTE_SCRATCH_PATH=/tmp/lidmute-task10-reviewfix-build zsh Scripts/make-app-bundle.sh`: exit 0; app created and ad-hoc signature replaced.
- `zsh Scripts/run-smoke-check.sh`: exit 0; 199 Swift test executions, 17 Node tests, two app-bundle builds, icon/extension/source contracts, and final `PASS LidMute smoke check`.
- Independent scoped re-review: `APPROVED`; the Host A backlog/Host B identity finding is resolved with no remaining findings. Reviewer additionally ran heartbeat, Native Messaging, App health, observation-clear, and App observation suites.
- Privacy/source scans: exit 0; no `kill(...)` liveness inference, one Logger construction confined to the typed adapter, exact `heartbeatInterval: 2`, exact `ttl: 6`, `ProcessInfo.processInfo.systemUptime`, and unchanged zero card spacing.
- `git diff --check`: exit 0.

## Formal review fix round 2 — stale acknowledgement and single-source presentation

### Important: stale acknowledgement health publication

- RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-red-build --filter staleAcknowledgementCannotPublishSuccessOrFailureHealthAfterClear`
- RED result: exit 1. The stale failure changed Chrome health from healthy to `permissionFailed`, and the stale success incorrectly cleared an existing `permissionFailed` state after clear advanced the observation boundary.
- GREEN command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-green-build --filter 'staleAcknowledgementCannotPublishSuccessOrFailureHealthAfterClear|backlogPresentationCannotDivergeFromNonfreshTypedHealth|lidUnavailableAndReadFailureHaveDistinctHealth'`
- GREEN result: exit 0; 3 test functions / 4 parameterized executions passed. Both acknowledgement success and failure now recheck lifecycle, clear state, and observation epoch after the awaited acknowledgement boundary before publishing health.

### Important: typed health is the sole Chrome presentation source

- RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-red-build --filter backlogPresentationCannotDivergeFromNonfreshTypedHealth`
- RED result: exit 1. Typed Chrome health was waiting while the independently stored legacy presentation reported `.receivedEvent` / `已接收 Chrome 标签页事件`.
- GREEN result: included in the combined GREEN command above. The legacy connection state, status copy, and manifest-repair capability are computed only from `health.chrome`; all direct legacy writers were removed.

### Important: I/O-free refresh retains local lid/recovery projection

- RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-red-build --filter lidUnavailableAndReadFailureHaveDistinctHealth`
- RED result: exit 1. Lid health remained `.unavailable` after the monitor recovered to `.state(false)` because removing Chrome health I/O from `refresh()` had also removed local health projection.
- GREEN result: included in the combined GREEN command above. `refreshLocalHealth()` now projects lid and recovery synchronously; both `refresh()` and `refreshHealth()` call it without putting Chrome file I/O back on the safety predecessor.
- Focused health suite: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-green-build --filter AppViewModelHealthTests` exited 0; 16 test functions passed, 0 failed.
- Focused observation suite: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-green-build --filter AppViewModelObservationTests` exited 0; 32 test functions passed, 0 failed, including both stale-acknowledgement parameter cases.

### Fresh verification after round 2

- Focused command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-final-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-final-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-final-build --filter 'AppViewModelHealthTests|AppViewModelObservationTests|ObservationClearTests|ChromeHostHeartbeatTests|ChromeNativeMessagingTests|ChromeHostRegistrationTests'`
- Focused result: exit 0; 16 XCTest cases plus 69 Swift Testing test functions passed with 0 failures.
- Full Swift command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-review2-full-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-review2-full-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-review2-full-build`
- Full Swift result: exit 0; 125 XCTest cases plus 86 Swift Testing test functions passed with 0 failures.
- Node command: `node --test ChromeExtension/service-worker.test.mjs`; exit 0, 17 passed, 0 failed.
- Visual command: `bash Scripts/check-visual-principles.sh`; exit 0 with `PASS visual principle source checks`.
- Bundle command: `LIDMUTE_SCRATCH_PATH=/tmp/lidmute-task10-review2-bundle-build zsh Scripts/make-app-bundle.sh`; exit 0, `dist/LidMute.app` created and its ad-hoc signature replaced.
- Smoke command: `zsh Scripts/run-smoke-check.sh`; exit 0 after 125 XCTest cases, 86 Swift Testing functions, 17 Node tests, visual checks, and app-bundle builds; final line `PASS LidMute smoke check`.
- Privacy/source scan and `git diff --check`: exit 0. The scan found exactly one Logger construction, no `kill(pid, 0)` liveness inference, exact 2-second heartbeat and 6-second TTL contracts, monotonic uptime, unchanged `cardSpacing: Double = 0`, and no event ID/title/URL/frame/evidence fields in `ChromeHostAcceptance`.
- Fresh independent scoped re-review: `APPROVED`, with no remaining findings. The reviewer independently passed 6 focused concurrency/safety regressions (including both stale-acknowledgement cases) and 19 XCTest plus 2 Swift Testing clear/lid/route/privacy regressions; confirmed health I/O remains outside the safety executor, shared locking and generation-fenced acceptance clear are sound, typed health is the sole Chrome presentation source, all preserved constraints remain intact, and no Task 11 changes were present.

## Self-review

- Speaker mutations remain exclusively behind `SpeakerRecoveryRuntime` / `SpeakerProtectionApplying`; `ProtectionCoordinator` was not given audio mutation capability.
- Heartbeat and diagnostic I/O do not enter the ordered speaker-safety path. Observation clear keeps its existing waits, epoch fencing, and lid/route processing.
- Manifest repair never accepts a new extension ID from editable UI state. It validates the already registered `chrome-origin.txt` value against exactly `[a-p]{32}` and requires it to match the sole manifest origin.
- Heartbeat cleanup synchronizes on the writer queue, cancels future timer work, waits behind an in-flight write, and performs the matching-session comparison and removal under the same cross-process file lock. Timer refresh also refuses to overwrite another session under that lock.
- Acceptance provenance contains no event ID, title, URL, frame, or tab evidence. The callback fires only for a newly durable normal-tab acceptance, never for duplicate, retryable, rejected, or incognito dispositions; clearing the inbox also removes the marker without changing observation persistence formats.
- Diagnostics contain only fixed messages and closed reason cases; the normal Chrome URL preservation and incognito rejection tests remain green.

## Manual risks not covered

- No interactive Chrome session was launched to observe a real Native Messaging Host heartbeat across browser suspension/restart.
- The new accepted-event callback and sidecar were unit-tested but not exercised against a live Chrome Native Messaging connection; callback ordering composes with the existing test that proves `ObservationStore.accepted` occurs only after inbox and metadata sync.
- No manual move of a signed `/Applications/LidMute.app` followed by clicking repair was performed; this is covered with real temporary JSON/origin files and an injected executable-file boundary.
- The UI was source-contract/build verified, not visually inspected in a running macOS window for every health combination.

## Formal review fix round 1 — shared heartbeat/acceptance locking

- Root cause: the heartbeat and acceptance stores opened independent descriptors and used process-owned `lockf` locks, so calls from separate store instances in the same process did not exclude each other. The pre-lock existence checks also sat outside the transaction boundary.
- RED command:
  - `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-lock-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-lock-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-lock-red-build --filter 'replacementCannotSlipBetweenSessionComparisonAndRemoval|heartbeatWriteWaitsForAnExternalFlockHolder'`
  - Result: exit 1. `replacementCannotSlipBetweenSessionComparisonAndRemoval` failed because the replacement completed before the paused removal was released (`.success` instead of `.timedOut`), then the old removal erased it (`.malformed` instead of the replacement's `.fresh` value). The real `/usr/bin/env lockf -k ...` subprocess test passed, establishing the pre-existing cross-process baseline.
- First GREEN attempt:
  - `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-lock-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-lock-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-lock-green-build --filter 'replacementCannotSlipBetweenSessionComparisonAndRemoval|heartbeatWriteWaitsForAnExternalFlockHolder'`
  - Result: exit 1 at compile time because Swift 6 resolves `Darwin.flock` to the imported `flock` structure rather than the C function. The implementation was corrected to bind the same POSIX `flock(2)` symbol explicitly as `systemFlock`.
- GREEN command:
  - `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-lock-green2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-lock-green2-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-lock-green2-build --filter 'replacementCannotSlipBetweenSessionComparisonAndRemoval|heartbeatWriteWaitsForAnExternalFlockHolder'`
  - Result: exit 0; 2 tests passed, 0 failed. The replacement remained blocked until removal released the shared in-process mutex, and the Swift write remained blocked behind the real subprocess lock holder.
- Final focused command after strengthening the subprocess assertion to decode the replacement heartbeat:
  - `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-lock-final-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-lock-final-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-lock-final-build --filter ChromeHostHeartbeatTests`
  - Result: exit 0; 8 test functions passed, 0 failed (including both parameterized impossible-uptime cases). The subprocess is stopped with bounded polling and a `SIGKILL` fallback; the final heartbeat was decoded and matched the expected session token/PID.
- Implementation: both stores now obtain one strongly held lock domain keyed by the standardized absolute sibling lock path. A shared `NSRecursiveLock` serializes all same-process instances; the outermost entry creates the private directory, opens the `0600` lock file with `O_CLOEXEC`, enforces its mode, acquires `flock(LOCK_EX)` with `EINTR` retry, and releases/closes it on unwind. Existence checks now execute inside that lock.
- `git diff --check -- Sources/LidMuteCore/ChromeHostHeartbeat.swift Tests/LidMuteCoreTests/ChromeHostHeartbeatTests.swift`: exit 0.

## Formal review fix round 1 — remaining findings

### Critical: health I/O cannot delay speaker safety

- RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix1-red2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix1-red2-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix1-red2-build --filter suspendedHealthIOCannotDelayALaterPhysicalLidClose`
- RED result: exit 1 in 0.115 seconds with `Expectation failed: closeArrivedBeforeHealthRelease`; a blocked heartbeat read held the MainActor and prevented two later physical-lid events from reaching the safety pipeline.
- GREEN command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix1-green2-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix1-green2-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix1-green2-build --filter suspendedHealthIOCannotDelayALaterPhysicalLidClose`
- GREEN result: exit 0; the regression passed in 0.006 seconds. Manifest/heartbeat/acceptance collection now runs in detached utility work, while MainActor publishes only a completed immutable result. Local protection refresh is I/O-free. `olderHealthCollectionCannotOverwriteANewerPublishedGeneration` separately passed in 0.006 seconds, proving an older suspended result cannot overwrite a newer publication.

### Important: stale Chrome poll health projections

- RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix4-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix4-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix4-red-build --filter staleChromePollCannotPublishSuccessOrFailureHealthAfterClear`
- RED result: exit 1; both parameterized cases failed. A stale successful batch and a stale thrown consume failure each published `permissionFailed` after clear had advanced the epoch.
- GREEN command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix4-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix4-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix4-green-build --filter staleChromePollCannotPublishSuccessOrFailureHealthAfterClear`
- GREEN result: exit 0; 2/2 cases passed. Lifecycle, shutdown, clear, and epoch fencing now precede success, failure, degradation, and storage-health projection.

### Important: non-fresh heartbeat and atomic Chrome presentation

- Heartbeat RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix5-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix5-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix5-red-build --filter missingOrMalformedHeartbeatWaitsForConnectionRatherThanClaimingBridgeFailure`
- Heartbeat RED result: exit 1; missing/malformed heartbeat published typed `.degraded` and legacy `Chrome 通信异常` instead of waiting.
- Presentation RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix6-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix6-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix6-red-build --filter typedAndLegacyChromePresentationPublishFromTheSameCompletedResult`
- Presentation RED result: exit 1 after the behavior-sensitive run; typed health became connected while legacy state remained `.unknown` / `等待 Chrome 扩展连接`.
- Focused GREEN command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-focused-app-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-focused-app-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-focused-app-green-build --filter AppViewModelHealthTests`
- GREEN result: exit 0; 14 test functions passed, 0 failed. Missing, stopped, corrupt, impossible, and stale heartbeat projections wait for connection; actual manifest/bridge failures remain degraded. Typed health, legacy connection state, status copy, and repair capability publish atomically from one completed result.

### Important: exact Native Messaging manifest contract

- RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix7-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix7-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix7-red-build --filter inspectAndRepairRejectInvalidFixedManifestContract`
- RED result: exit 1 with 6 issues across 4 cases; inspect accepted wrong fixed name/type and illegal or mismatched origins, while repair accepted wrong name/type.
- GREEN command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-focused-app-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-focused-app-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-focused-app-green-build --filter ChromeHostRegistrationTests`
- GREEN result: exit 0; 4 test functions / 7 executions passed. Inspect and repair both require exact `com.lidmute.nativehost`, exact `stdio`, a string description/path, and exactly one legal origin matching the registered origin file.

### Important: acceptance marker clear linearization

- Clear-failure RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix3-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix3-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix3-red-build --filter acceptanceMarkerClearFailureIsReportedInsteadOfSilentlySwallowed`
- Clear-failure RED result: exit 1; the coordinator received an empty failure list and the UI remained empty because marker removal used `try?`.
- Generation RED command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix3-generation-red-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix3-generation-red-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix3-generation-red-build --filter acceptanceMarkerFromClearedGenerationCannotRemainRecent`
- Generation RED result: exit 1; a generation-0 marker remained fresh after observation generation advanced to 1.
- GREEN commands:
  - `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix3-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix3-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix3-green-build --filter acceptanceMarker`
  - `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix3-green-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix3-green-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix3-green-build --filter newAcceptanceCannotSlipBetweenGenerationAdvanceAndMarkerReset`
- GREEN result: exit 0; 3 marker tests passed, and the transaction regression passed in 0.207 seconds. Acceptance schema version 2 carries the observation generation. Clear advances generation and removes the marker within the observation lock, reports `.acceptance` on failure, and fences outstanding health collection. Native Host accepted-callback marker writes use the same observation-lock transaction, so a post-clear acceptance cannot be removed by the older clear.

### Focused cross-checks after all review fixes

- `ChromeHostHeartbeatTests`: 9 test functions passed, 0 failed, including same-process replacement exclusion, real subprocess `flock`, and generation-aware acceptance.
- `ObservationClearTests`: 8 passed, 0 failed.
- `ChromeNativeMessagingTests`: 16 XCTest cases passed, 0 failed.
- `AppViewModelObservationTests`: 31 test functions / 32 executions passed, 0 failed.

### Final verification after formal-review fixes

- Full Swift command: `CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task10-fix1-final-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task10-fix1-final-swiftpm swift test --disable-sandbox --scratch-path /tmp/lidmute-task10-fix1-final-build`
- Full Swift result: exit 0; 125 XCTest cases and 84 Swift Testing test functions passed with 0 failures.
- Node command: `node --test ChromeExtension/service-worker.test.mjs`
- Node result: exit 0; 17 passed, 0 failed.
- Visual command: `bash Scripts/check-visual-principles.sh`
- Visual result: exit 0; `PASS visual principle source checks`.
- Bundle command: `LIDMUTE_SCRATCH_PATH=/tmp/lidmute-task10-fix1-bundle-build zsh Scripts/make-app-bundle.sh`
- Bundle result: exit 0; `dist/LidMute.app` was created and its ad-hoc signature replaced successfully.
- Smoke command: `zsh Scripts/run-smoke-check.sh`
- Smoke result: exit 0 after the full Swift/Node runs, two visual checks, and two app-bundle builds; final line `PASS LidMute smoke check`.
- Privacy/source scan: exit 0 with `set -e`; one Logger construction only, no `kill(pid, 0)` liveness inference, exact 2-second heartbeat, exact 6-second TTL, monotonic uptime calls only, unchanged `cardSpacing = 0`, and no event ID/title/URL/frame/evidence fields in `ChromeHostAcceptance`.
- `git diff --check`: exit 0.
