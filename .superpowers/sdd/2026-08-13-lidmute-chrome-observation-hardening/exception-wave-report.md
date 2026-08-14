# Exception Wave Report

## Scope

This explicitly authorized exception wave starts from `606902e842af7ee69994de5b370a38a310f3659a`. It resolves the five independently verified residual findings after the final wave without changing the control layout, Chrome registration contract, speaker-source priority, pending-delivery generation boundary, or alarm-based retry architecture.

## Finding resolutions

### 1. Chrome safety acknowledgement is distinct from generic speaker recovery

- Added `ChromeSafetyDeliveryResult` and the dedicated `ProtectionCoordinator.ensureProtected(for:)` seam.
- Removed Chrome durable-ACK policy from `SpeakerRecoveryOutcome`; a generic `noPendingRecovery` no-op can no longer delete a pending Chrome delivery.
- With no active protection source, the coordinator returns the explicit benign `notRequired` result. With an active source, it uses `routeChangedWhileProtectionRequired`, which either reinforces the journaled device or recreates and verifies protection when the journal/route is unavailable.
- Only an applied, verified `.protected` or `.verifiedSilent` result is safe while protection is required. Unavailable/corrupt/unknown outcomes remain `.unsafe` and retain the pending delivery.
- Two pending replays are covered: the first unavailable result is not acknowledged; a second poll retries the same delivery and acknowledges only after the matching route is actually protected.

### 2. Mixed acknowledgement streams retain durable retry

- A terminal acknowledgement now persists its filtered outbox inside the serialized mutation and resets retry state only when that persisted outbox is empty.
- If another event remains, the same serialized mutation re-ensures the durable retry deadline/alarm.
- Fire-and-forget Chrome lifecycle and listener promises have a terminal rejection handler. A rejected alarm creation leaves the persisted deadline intact, and a later startup restoration recreates the missing alarm without an unhandled rejection.
- No service-worker timer retry state was reintroduced.

### 3. Chrome poll single-flight covers safety delivery and durable ACK

- `enqueueProtectionEvent` now returns its task, and `pollChromeInbox()` awaits that exact task through coordinator safety delivery and durable pending acknowledgement.
- The poll in-flight guard therefore covers the complete delivery chain. A second poll after the production 0.7-second interval cannot consume or enqueue the same pending batch while the first delivery is suspended.
- Observation clear captures and awaits the same task before entering its coordinator and persistent clear boundaries.

### 4. Typed clear completion clears both Chrome-evidence owners consistently

- `endObservationClear` now accepts `ObservationClearReport?`.
- App passes the typed report for complete or partial clear and passes `nil` when persistent clear throws.
- The coordinator clears `latestChromeEvidence` only when `.inbox` is confirmed cleared. An inbox failure or unknown completion retains the full title and URL.
- This evidence-only reset does not clear active protection sources or change the protecting state.

### 5. Coordinator and operational storage health recover independently

- App now stores `coordinatorStorageHealth` separately from typed operational/clear health.
- `storageStatusText` and `storageStatusSeverity` are derived from both channels. Concurrent faults are presented together in stable order; partial clear is a warning and persistence faults remain errors.
- A healthy update clears only its originating channel. A still-persistent fault in the other channel remains visible.
- Because App retains the last coordinator health, later operational failure/recovery recomputes correctly even when `ProtectionCoordinator` suppresses an identical callback.

## TDD evidence

- Chrome safety seam RED: the coordinator test failed to compile because `ensureProtected` and the dedicated result did not exist. The App integration RED then failed protocol conformance while the App still consumed `SpeakerRecoveryOutcome`. GREEN: the coordinator retries unavailable active protection twice (`unsafe`, then `protected`), and the replaying App consumer withholds then emits the durable ACK.
- Mixed ACK RED: the scheduler observed only `[[retryable, terminal]]`; the retained retryable event was not scheduled after terminal filtering. GREEN: it additionally observes `[retryable]`, never calls `succeed` while retained work exists, and clears retry only after the final terminal ACK.
- Scheduler rejection RED: injected first alarm creation produced an unhandled fire-and-forget rejection. GREEN: no unhandled rejection is observed, the deadline remains persisted, and startup recreates the same alarm.
- Poll single-flight RED: after 0.7 seconds the second poll increased `consumeCount` from the expected `1` to `2`, and the first poll returned before ACK. GREEN: one consume/one coordinator delivery remains in flight until the exact durable ACK completes; clear also waits it.
- Clear evidence REDs: the typed report call initially failed to compile; an unconditional success implementation then erased title/URL on `.inbox` failure; App doubles finally exposed the old untyped protocol. GREEN: successful clear removes the coordinator evidence, partial inbox failure retains it, and App passes the report.
- Health channels RED: the App had no `storageStatusSeverity`, and the shared text/owner model could not satisfy either failure/healthy ordering. GREEN: both orderings pass without a repeated coordinator callback.

## Fresh verification gates

- Focused Swift:
  - `AppViewModelObservationTests`: 25/25 passed.
  - `ProtectionCoordinatorJournalIntegrationTests`: 14/14 passed.
- Full Swift: `swift test --disable-sandbox` passed 124 XCTest tests and 43 Swift Testing tests.
- Chrome: `node --test ChromeExtension/service-worker.test.mjs` passed 14/14.
- Chrome smoke import exited 0 without a Chrome global.
- `bash Scripts/check-visual-principles.sh` passed.
- `zsh Scripts/make-app-bundle.sh` built, linked, copied extension resources, ad-hoc signed, and created `dist/LidMute.app`.
- Full smoke passed 124 XCTest, 43 Swift Testing, 14 Node tests, visual checks, and two bundle builds.
- Required scans returned zero matches for silent JSON skipping, whole-inbox reads, per-event full-history reload, sorted dedup suffixes, `setTimeout`, `retryTimer`, and `reconnectTimer`.
- `git diff --check` passed.

The first smoke invocation used a nonexistent explicit `TMPDIR` and stopped before build/test with `couldNotFindTmpDir`. It was rerun from a fresh `mktemp` directory and completed the full gate successfully. Expected sandbox user-cache and FSEvents warnings remained non-fatal.

## Remaining manual-only gaps

- No live Chrome MV3 worker was killed between a rejected alarm creation and a startup restoration; deterministic Node lifecycle tests cover the durable deadline and recreation contract.
- No physical audio-route removal/reappearance was performed; deterministic coordinator and speaker-runtime tests cover unavailable-to-matching-route protection.
- No real disk was filled and no Application Support permission was revoked; fault-injectable stores cover typed failures and independent recovery presentation.
- No manual UI interaction was performed. Layout metrics were unchanged; automated visual, bundle, and smoke gates passed.
