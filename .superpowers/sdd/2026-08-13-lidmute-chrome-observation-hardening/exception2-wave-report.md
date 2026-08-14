# Exception 2 Wave Report

## Scope

This explicitly authorized second exception wave starts from `57bf98827faa7d7c57617b9170d2d3e9d8d4e62a`. It resolves only the three remaining Important findings: rejected Chrome alarm cleanup, stale poll presentation after observation clear, and operational storage-health channel interference. It does not change the control layout, protection-source policy, pending-delivery safety boundary, or alarm-based retry architecture.

## Finding resolutions

### 1. Rejected alarm cleanup cannot consume durable retry liveness

- Alarm fire and overdue restore first persist the next backoff state, then treat removal of the already-fired or stale alarm as best-effort. A rejected `alarms.clear()` no longer prevents the retry/reconnect callback.
- The retry callback can immediately establish the next durable deadline and replace the old named alarm. Failures to persist state or create/get an alarm still propagate, preserving the existing startup-recovery contract.
- When a terminal acknowledgement empties the outbox, retry state remains removed even if alarm cleanup rejects. The acknowledgement resolves, and a later startup restore removes the stale alarm without reconnecting an empty outbox.

### 2. Observation clear owns presentation after its epoch begins

- `pollChromeInbox()` already captures the observation epoch before consuming. After awaiting its complete safety-delivery and durable-ACK task, it now revalidates ready lifecycle, shutdown state, clear ownership, and the captured epoch before changing the last-event time, connection status, bridge text, or current-source presentation.
- A controlled test suspends delivery, starts clear, resumes both MainActor waiters, and pauses persistent clear. The stale poll cannot republish `已接收 Chrome 标签页事件` while clear owns the epoch.
- The existing partial-clear policy remains explicit: an `.inbox` failure retains an already-established Chrome presentation, while a successful inbox clear resets it.

### 3. Storage health recovers independently by operation

- App health now has typed `startupHealth`, `consumeHealth`, `ackHealth`, and `clearHealth` channels in addition to `coordinatorStorageHealth`.
- A successful consume clears only consume health; a successful durable ACK clears only ACK health; a complete or partial clear updates only clear health. A startup history-read fault is not erased by later operational success.
- Presentation is derived in stable coordinator, startup, consume, ACK, clear order. Duplicate text is still presented once, and severity is the maximum of every channel that remains unhealthy, so a clear warning cannot hide or downgrade a persistence error.

## TDD evidence

- Alarm fire RED: one injected clear rejection caused `fire()` to reject with zero retry callbacks after the persistent deadline had been removed. GREEN: retry runs once and re-arms deadline `23_000` with doubled backoff.
- Overdue restore RED: the same rejection caused `restore()` to skip retry. GREEN: retry runs once and re-arms deadline `24_000`.
- Terminal empty-outbox RED: terminal acknowledgement rejected after persisting the empty outbox and removing retry state. GREEN: it resolves; startup removes the stale alarm and the retry count remains zero.
- Poll/clear RED: while persistent clear was deliberately paused, the resumed stale poll changed the bridge status from empty/waiting to received. GREEN: post-await epoch ownership keeps the status empty/waiting regardless of waiter resumption order.
- Health RED: ACK capacity failure followed by consume permission failure and partial clear produced five failed expectations because the shared operational channel successively hid faults and downgraded severity. GREEN: all three faults remain in stable order; consume recovery, ACK recovery, and clear recovery remove only their own entries.

## Fresh verification gates

- Focused Swift: `AppViewModelObservationTests` passed 29/29.
- Full Swift: `swift test --disable-sandbox` passed 124 XCTest tests and 47 Swift Testing tests.
- Chrome: `node --test ChromeExtension/service-worker.test.mjs` passed 17/17.
- Chrome smoke import exited 0 without a `chrome` global.
- `bash Scripts/check-visual-principles.sh` passed.
- `zsh Scripts/make-app-bundle.sh` built, linked, copied Chrome resources, ad-hoc signed, and created `dist/LidMute.app`.
- `zsh Scripts/run-smoke-check.sh` passed the full Swift, Node, visual, artifact, and double-package gate from an isolated temporary scratch directory.
- Required scans returned zero matches for silent JSON skipping, whole-inbox reads, per-event full-history reload, sorted dedup suffixes, `setTimeout`, `retryTimer`, and `reconnectTimer`.
- `git diff --check` passed.

Expected sandbox user-cache and FSEvents warnings remained non-fatal.

## Remaining manual-only gaps

- No live Chrome MV3 worker was suspended between an injected `alarms.clear()` rejection and its subsequent wake/startup; deterministic scheduler tests cover both wake paths and terminal empty-outbox convergence.
- No manual AppKit interaction was performed. The control layout was not modified; automated visual, bundle, artifact, and smoke gates passed.
- No real disk or Application Support permission failure was induced. Fault-injectable stores and consumers cover crossed operational faults and independent recovery.
