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
