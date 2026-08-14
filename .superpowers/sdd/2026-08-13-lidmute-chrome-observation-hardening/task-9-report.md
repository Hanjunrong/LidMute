# Task 9 Report: bounded observation storage, clear barrier, and incremental App consumption

## Result

Task 9 now uses one shared recursive cross-process observation lock for accept, consume, event append, and clear. The event timeline retains the newest 5,000 valid records, Chrome inbox consumption commits only complete records with a durable cursor/remainder, and clear advances a monotonic generation before removing observation state. App presentation consumes only after lifecycle readiness, inserts events incrementally, and reports partial clear failures without removing Chrome registration.

## RED / GREEN evidence

### Group 1: bounded event storage and explicit health

- RED: `swift test --filter BoundedEventStoreTests` failed to compile because `BoundedJSONLineEventStore` and `EventStoreError` did not exist.
- GREEN: six boundaries (`0`, `1`, `4,999`, `5,000`, `5,001`, `10,000`) and corrupt-record health passed. The boundary fixture bulk-seeds `total - 1` valid lines and exercises the production append/rewrite for the final boundary, avoiding an O(n²) test while still reopening the real file.
- Checkpoint: `e079e83 feat: bound local event history to five thousand`.

### Group 2: durable incremental Chrome consumer

- RED 1: `swift test --filter ChromeInboxConsumerTests` failed to compile because consumer/cursor/error types did not exist.
- GREEN 1: half-line, cursor-commit failure replay, inode replacement, and complete corrupt-line cases passed.
- RED 2: a range-read mutation check failed with observed offsets `[]` instead of `[0, 308]`, proving the first implementation still read the whole inbox.
- GREEN 2: production now uses `pread` from `offset + remainder.count`; all four consumer tests passed. Cursor commit occurs only after idempotent event append and file/directory sync.

### Group 3: monotonic generation clear barrier

- RED: `swift test --filter ObservationClearTests` failed to compile because clear report/category/API types did not exist.
- GREEN: five tests passed for complete clear, registration preservation, explicit partial inbox failure, accept/clear exclusion, and consume/clear exclusion.
- Debug note: the first concurrency run hung because the test called `eventStore.recent()` from another thread while consumer intentionally held the shared lock at the cursor pause. Four non-consume tests passed in isolation, confirming the fixture fault. The assertion was changed to inspect the already-synced events file; the production lock was not bypassed or weakened.

### Group 4: App lifecycle, incremental events, and clear presentation

- RED: `swift test --filter AppViewModelObservationTests` failed for missing lifecycle provider, dependency injection, polling, incremental callback, clear API, and storage status.
- GREEN: five tests passed. Recovering state performs zero consumes; ready state consumes once; startup reads history once; callbacks do not reload history; UI remains newest-first and capped at 5,000; clear resets event/Chrome presentation and consumer state while retaining extension ID; partial failures are visible.
- Chrome timer creation was removed from `startAll()`. It starts only after the lifecycle coordinator has published `.ready`, including startup, recovery resume, and route-recovery convergence.

### Legacy replacement required by the final scan

The plan's required source scan still found the retired `JSONLineEventStore` silent `compactMap`, plus the retired sorted-set Chrome deduplicator. `rg` proved these types had no production users and were referenced only by `ExistingBehaviorTests`.

- RED: after deleting the dead types, targeted compilation failed only at the three legacy test references.
- GREEN: the malformed event test now asserts `EventStoreError.corruptRecord(line: 2)` and typed health; obsolete bridge/dedup tests were removed because strict `ChromeFrameDecoder` and ordered `ObservationStore` tests cover their replacements.
- Ownership extension: `Sources/LidMuteCore/ChromeProtocol.swift` and `Tests/LidMuteCoreTests/ExistingBehaviorTests.swift` were touched only to satisfy the brief's required zero-match scan; Task 7 strict decoder/validated-frame code was unchanged.

## Final verification

- `swift test`: 115 XCTest tests, zero failures; 16 Swift Testing tests, zero failures (including six parameterized capacity cases).
- `node --test ChromeExtension/service-worker.test.mjs`: 7 passed, 0 failed.
- `bash Scripts/check-visual-principles.sh`: `PASS visual principle source checks`.
- `zsh Scripts/make-app-bundle.sh`: fresh build, stale-binary check, resources, icon, Chrome extension, and ad-hoc signing succeeded.
- `zsh Scripts/run-smoke-check.sh`: full Swift + Node verification, two consecutive bundle builds, icon/manifest checks, and `PASS LidMute smoke check`.
- Required source scan: no matches for silent JSON corruption skipping, whole-inbox App reads, per-callback history reloads, or sorted dedup suffixes.
- `git diff --check`: clean.

## Manual gaps

- No real disk was filled to force `ENOSPC`, and no real Application Support directory permissions were revoked. Production maps `ENOSPC`/`EDQUOT` to capacity health and `EACCES`/`EPERM` to permission health; automated tests exercise explicit corrupt health and injected partial/commit failures.
- Crash/retry is tested by failing cursor persistence after the event append, then constructing a fresh consumer. The test does not send `SIGKILL` to a separate App process.
- Chrome registration preservation is tested with real files in an isolated temporary support root. The user's installed Chrome manifest and origin were not modified.
- No manual visual interaction was performed; layout was intentionally unchanged apart from clear progress/status text, and source visual checks plus bundle smoke passed.

## Review fix round 1

### Result

Chrome inbox batches now rewrite the bounded event history at most once, cursor-commit retries redeliver live evidence without duplicating persisted history, and empty polls perform no event-history I/O. App polling performs consumer storage work off `MainActor` with a single-flight guard. Clear establishes an observation epoch fence, pauses polling, drains or invalidates queued Chrome delivery, flushes observation logging, and only then runs the generation clear. Asynchronous protection transitions apply speaker safety before observational persistence and use a separate serial detached logging FIFO; the synchronous compatibility path remains synchronous.

### RED / GREEN evidence

#### Batch persistence and cursor retry delivery

- RED: two complete inbox records produced `eventReadCount == 2` and `eventWriteCount == 2`; retry after a successful event append plus failed cursor commit returned `records == []`; consequently the App received no live retry presentation.
- GREEN: `appendBatchReporting` reads the bounded history once, deduplicates the entire incoming batch by `observationEventID`, and performs at most one atomic rewrite. Consumer delivery is independent of insertion: a normal same-generation/same-inode retry is redelivered, while generation/inode/truncation normalization suppresses already-persisted replacement records. The consumer suite passes with one read/one write for two records, one persisted event across cursor retry, and live App presentation on retry.
- Additional RED / GREEN: an empty poll still read the full event history once. An explicit empty-batch fast path now leaves event read/write counts at zero.

#### MainActor isolation

- RED: a pausing consumer timed out before the MainActor probe could run; by the time execution returned, the Chrome presentation had already mutated.
- GREEN: `pollChromeInbox()` is async, runs `consumeAvailable()` in a utility detached task, rejects overlapping polls, and mutates presentation only after the batch returns to `MainActor`. The controlled test observes the consumer paused off actor, a successful MainActor probe, no premature event insertion, and correct insertion after resume.

#### Clear epoch and FIFO fence

- RED: the controlled two-delivery clear test initially failed to compile because App had no injectable Chrome delivery/flush seam, reflecting the absence of a way to invalidate or drain queued delivery work.
- GREEN: each poll and queued delivery captures `observationEpoch`. Clear increments the epoch, pauses the timer, waits the captured protection-delivery FIFO, flushes observation logging, and then clears persistent and in-memory state. In the controlled test, the first delivery is allowed to finish, the stale second delivery is skipped (`receiveCount == 1`), logging is flushed once, and event/Chrome presentation remains empty after clear.

#### Speaker safety before observation logging

- RED: with `EventStoring.append` paused on `.lidClosed`, the timeline showed `store.lidClosed` at index 1 and `protection.begin` at index 2. The MainActor probe and the following `.end` transition could not proceed while storage was paused.
- GREEN: the asynchronous coordinator path buffers events produced by prepare/complete, applies the speaker transition first, and enqueues the batch onto a detached serial logging FIFO without awaiting it from the safety-transition FIFO. `onEvent` returns to `MainActor` only after each append attempt. While the store is paused, `.begin` has already applied, the MainActor probe runs, and `.end` also applies; after resume, all five observation events are persisted in strict FIFO order. `flushObservationLogging()` provides the clear barrier.

### Review-round verification

- Focused Swift regression filter (`ChromeInboxConsumerTests|AppViewModelObservationTests|ObservationClearTests|ProtectionCoordinator`): 8 XCTest tests and 19 Swift Testing tests passed.
- Full `swift test --disable-sandbox --scratch-path /tmp/lidmute-task9-fix-build`: 116 XCTest tests and 21 Swift Testing tests passed.
- `node --test ChromeExtension/service-worker.test.mjs`: 7 passed, 0 failed.
- `bash Scripts/check-visual-principles.sh`: `PASS visual principle source checks`.
- `zsh Scripts/make-app-bundle.sh`: fresh Swift build, resource assembly, stale-binary check, icon generation, and ad-hoc signing passed.
- `zsh Scripts/run-smoke-check.sh`: full Swift and Node suites, two bundle builds, icon/manifest checks, and `PASS LidMute smoke check`.
- Required source scan: no matches for silent JSON corruption skipping, whole-inbox App reads, per-callback history reloads, or sorted dedup suffixes.
- `git diff --check`: clean.

### Review-round manual gaps

- Concurrency is exercised with deterministic pausing test doubles rather than a real saturated or stalled disk.
- Cursor retry is injected at cursor persistence rather than by killing a live App process between event and cursor commits.
- No installed Chrome extension, real Application Support data, or live speaker state was modified. No UI layout changes were made.
