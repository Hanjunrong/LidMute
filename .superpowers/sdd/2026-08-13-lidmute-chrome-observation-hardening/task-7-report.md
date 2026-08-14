# Task 7 Report: Native Host validated framing, durable ACK, and idempotent inbox

## Outcome

Task 7 is implemented on `fix/lidmute-reliability-hardening`.

- Chrome Native Messaging uses incremental 4-byte little-endian framing with a 262,144-byte ceiling.
- The Native Host validates the complete required wire schema, RFC 4122 UUID text via `UUID(uuidString:)`, and every specified UTF-8 byte limit before persistence.
- Normal observations retain the complete URL, including query and fragment.
- Incognito observations return `ignored_incognito` without writing title, URL, evidence, or raw payload to inbox, dedup metadata, events, or diagnostics.
- `ObservationStore` holds a recursive cross-process `flock` while reading generation, appending one generation-tagged record, syncing the inbox, updating ordered recent-4,096 dedup metadata, and syncing the parent directory.
- Acceptance retries reconcile an already-durable inbox record after metadata failure and redrive all sync points after a directory-sync failure before returning terminal `duplicate`.
- The Native Host writes only framed ACK JSON to stdout. Privacy-safe reason tokens go to stderr; partial EOF and unaddressable malformed payloads disconnect without an ACK.
- No automatic media behavior was added.

## Checkpoint 1: Incremental framing

RED:

- Added XCTest coverage for split prefixes, split UTF-8 payloads, glued frames with a trailing partial frame, and an oversized prefix.
- `swift test --filter ChromeNativeMessagingTests` failed to compile with `cannot find 'NativeMessageFramer' in scope` and missing `NativeMessageFramingError`.

GREEN:

- Added `NativeMessageFramer` and `NativeMessageFramingError`.
- Focused result: 3 tests, 0 failures.

Commit: `8250784` (`feat: parse incremental Chrome native frames`)

## Checkpoint 2: Validated schema and privacy classification

RED:

- Added XCTest coverage for the complete required schema, version/type/audible rules, both UUIDs, all specified UTF-8 byte limits, full URL preservation, and incognito classification.
- Focused compilation failed with missing `ChromeFrameDecoder`, `ChromeValidatedFrame`, `ChromeFramePrivacy`, and `ChromeFrameValidationError`.

GREEN:

- Added strict private wire DTOs with required fields and typed validation errors.
- Used `Data(string.utf8).count` for title, URL, status, mute reason, extension ID, and bounded ID checks.
- Focused result: 8 tests, 0 failures.

Commit: `d20649c` (`feat: validate Chrome observation frames`)

## Checkpoint 3: Durable store, generation, lock, and idempotency

RED:

- Added XCTest acceptance coverage for fsync order, retryable capacity/permission failures, explicit corruption health, restart duplicates, zero persisted incognito bytes, generation tagging, ordered recent-4,096 IDs, `0700`/`0600` modes, and recursive locking.
- Focused compilation failed with missing `ObservationStore`, `ObservationPaths`, `ObservationFileSystem`, and observation lock types.

GREEN:

- Added `ObservationPaths`, generation-tagged `ChromeInboxRecord`, `ObservationStore`, injectable filesystem/lock contracts, `POSIXObservationFileSystem`, `InProcessObservationLock`, and recursive `POSIXObservationLock`.
- The initial focused result was 10 tests, 0 failures.

Crash-window RED/GREEN:

- A dedup-write failure after inbox fsync initially caused retry to return `accepted` and append a second inbox line. The regression failed with two inbox records; reconciliation from the durable inbox made it pass with one record and terminal `duplicate`.
- A parent-directory fsync failure initially let retry return `duplicate` without re-syncing inbox, dedup, and directory. The regression failed with one sync at each point instead of two; retry now verifies the inbox record and redrives all three sync points before the terminal disposition.
- Final focused result: 12 tests, 0 failures.

Commits:

- `c7a6fc7` (`feat: durably accept validated Chrome observations`)
- `b90673b` (`fix: redrive duplicate durability before acknowledgement`)

## Checkpoint 4: ACK session and Native Host integration

RED:

- Added XCTest coverage for all terminal store dispositions, retryable persistence/corruption health, permanent validation rejection with a bounded UUID, unaddressable malformed payload disconnect, partial-frame buffering, and the exact ACK JSON field contract.
- Focused compilation failed with missing `NativeHostSession`, `ChromeAcknowledgement`, `ChromeAckDisposition`, and `ChromeFrameAccepting`.

GREEN:

- Added exact ACK disposition mapping and safe event-ID envelope extraction.
- Connected `LidMuteNativeHost` to `LidMuteCore`, `ObservationStore`, and `NativeHostSession`.
- Replaced the raw append/optimistic ACK loop with complete-frame receive, validated durable acceptance, framed ACK output, and privacy-safe stderr failures.
- Focused result: 15 tests, 0 failures.

Commit: `c7a6fc7` (`feat: durably accept validated Chrome observations`)

## Final verification

All commands used XCTest for Swift tests.

- `swift test --filter ChromeNativeMessagingTests`: 15 tests, 0 failures.
- `swift test --filter ObservationStoreAcceptanceTests`: 12 tests, 0 failures.
- `swift test`: 112 tests, 0 failures.
- `zsh Scripts/make-app-bundle.sh`: PASS; produced and signed `dist/LidMute.app` with `LidMuteNativeHost`.
- `zsh Scripts/run-smoke-check.sh`: PASS.
  - Swift: 112 tests, 0 failures.
  - Chrome extension Node tests: 2 tests, 0 failures.
  - Visual checks, executable checks, extension manifest checks, icon checks, and two consecutive packaging runs passed.
- `git diff --check`: PASS.

Independent review was scheduled by the root orchestrator after the final diff package was produced.

## Review fix round 1: bounded suffix reconciliation

Ruling:

- Review found that a dedup miss full-decoded the unbounded inbox and treated any historical inbox match as a duplicate. Replaying an ID older than the 4,096-entry window then mutated recent metadata without creating a new acceptance, so the metadata no longer represented the latest 4,096 acceptances.
- An exact all-history UUID membership index was considered and rejected. It would retain dedup IDs beyond the plan's explicit ordered `suffix(4_096)` contract and grow without bound. The Task 7 guarantee remains bounded: an ID outside the recent window is accepted again and becomes the newest acceptance.
- Crash reconciliation now reads backward in bounded chunks, decodes at most the newest 4,096 complete inbox records, and rebuilds recent metadata from the current generation's actual suffix. No auxiliary membership index or marker is persisted, and incognito observations still return before any inbox, dedup, or tail-read operation.

RED:

- Added seeded-state XCTest regressions for replay beyond the dedup window and restart after an inbox-fsync/dedup-write crash window. The filesystem spy rejected any full inbox read so the test could not pass through the old unbounded path.
- The two-test focused run completed in 0.23 seconds with 7 assertion failures, including unexpected `retryablePersistenceFailure` results caused by the rejected full inbox reads.

GREEN:

- Replaying the evicted ID now returns `accepted`, appends exactly one inbox record, and rotates the ordered recent suffix to `oldRecent.dropFirst() + replayedID`.
- A restart after a dedup-write failure rebuilds the current generation's recent suffix from the bounded inbox tail before accepting the next event. Retrying the recovered in-window event remains terminal `duplicate` without a second inbox record.
- Existing dedup-write recovery, directory-sync redrive, exact 4,096 order, corruption, permissions, generation, and zero-persistence incognito tests remain green.

Review-round verification:

- Focused new regressions: 2 tests, 0 failures.
- `swift test --filter ObservationStoreAcceptanceTests`: 14 tests, 0 failures.
- `swift test --filter ChromeNativeMessagingTests`: 15 tests, 0 failures.
- `swift test`: 114 tests, 0 failures.
- `zsh Scripts/make-app-bundle.sh`: PASS; produced and signed `dist/LidMute.app`.
- `zsh Scripts/run-smoke-check.sh`: PASS, including 114 Swift tests, 2 extension tests, visual/manifest/executable/icon checks, and two consecutive packaging runs.
- `git diff --check`: PASS.
