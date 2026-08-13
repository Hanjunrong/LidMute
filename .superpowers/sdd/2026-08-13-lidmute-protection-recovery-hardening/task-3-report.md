# Task 3 Report

## Status

DONE

## Changes

- Replaced the shared lid protection source with independent `.physicalLid`, `.simulation`, and `.night` sources.
- Added `SimulationLidState.closed`, `.opened`, and `.reset`, plus `receivePhysicalLid(closed:)` and `receiveSimulation(_:)` coordinator entry points.
- Routed system lid monitor callbacks exclusively to the physical source; simulation controls exclusively to the simulation source; simulation no longer changes `latestSystemLidClosed`.
- Preserved `receiveLidState(closed:simulated:)` as a compatibility forwarder for existing callers/tests, while all app entry points use the new explicit APIs.
- Added five source-interleaving regression tests: physical/simulation cross-release prevention, simulation reset isolation, duplicate/out-of-order input idempotency, and multi-source disable restoration.

## RED

Initial command:

```bash
swift test --filter ProtectionSourceStateTests
```

Observed: SwiftPM could not compile the package because its default Clang module cache at `~/.cache/clang/ModuleCache` was not writable in the sandbox. The test did not reach the intended interface check.

Isolated-cache RED command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests
```

Observed: exit 1 after compiling the package. `ProtectionSourceStateTests.swift` failed as expected because `ProtectionCoordinator` had no `receivePhysicalLid` or `receiveSimulation` members, and simulation case inference consequently failed.

## GREEN

Focused command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests
```

Observed: exit 0; 5 tests executed, 0 failures.

Full command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-swiftpm-module-cache \
swift test
```

Observed: exit 0; 33 tests executed, 0 failures.

## Self-review

- `activeSources` is now a set of three independent sources, so a transition for one source cannot remove another source's protection.
- The coordinator restores only after the final active source is removed; disabling restores through the single guard-disable path before clearing every source.
- Duplicate physical and simulation observations are ignored before they can cause repeated silence mutations; `.reset` clears only the simulation observation/source.
- System callbacks and simulation controls use the new explicit APIs; manual `MediaCommand` behavior and app visual layout are untouched.
- `git diff --check` passed.

## Review Fix Round 2

### Finding addressed

Resetting the simulation while the guard was disabled updated the UI state but was not sent to the coordinator. The retained simulated-closed observation could therefore be replayed at the next enable.

### RED

An initial direct `AppViewModel` test was intentionally discarded: the Core test target cannot link the `LidMuteApp` executable target, and changing package target architecture was outside Task 3 scope. The final RED exercises the extracted Core lifecycle boundary used by all App simulation actions.

Command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review2-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review2-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests.testLifecycleRouterDeliversDisabledResetBeforeReenable
```

Observed: exit 1 at compile time as expected; `SimulationProtectionLifecycle` was not in scope. This test names the missing lifecycle boundary whose required behavior is that `.reset` reaches the coordinator while disabled, so re-enable remains armed.

### GREEN

Added a small Core `SimulationProtectionLifecycle` that unconditionally routes each simulation state to the coordinator. `AppViewModel` now uses that single lifecycle route for close, open, and reset; reset has no guard-enabled condition.

Focused command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review2-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review2-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests.testLifecycleRouterDeliversDisabledResetBeforeReenable
```

Observed: exit 0; 1 test executed, 0 failures.

Covering matrix command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review2-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review2-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests
```

Observed: exit 0; 7 tests executed, 0 failures.

Full command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review2-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review2-swiftpm-module-cache \
swift test
```

Observed: exit 0; 35 tests executed, 0 failures.

### Review self-check

- The lifecycle regression fails if reset is dropped while disabled, because re-enable would replay the retained closure and become protecting.
- App simulation close/open/reset all use the same Core lifecycle route; reset is unconditional.
- No package architecture change or deferred Minor finding was included.
- `git diff --check` passed.

## Commit

Implementation commit recorded after this report using the Task 3-required message and OMC trailers.

## Concerns

None.

## Review Fix Round 1

### Finding addressed

Re-enabling the guard after a simulated closure could leave the coordinator armed: disabling cleared the simulation observation and source, while the UI remained simulated-closed and would not submit a duplicate close event.

### RED

Command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests.testEnablingReplaysSimulatedClosedStateObservedWhileDisabled
```

Observed: exit 1; the new lifecycle regression failed as expected with coordinator state `armed` rather than `protecting`, and zero silence mutations rather than one.

### GREEN

The regression now exercises the user-visible lifecycle: simulated close, disable, then enable. The coordinator retains only the simulation observation across disable, clears its active source, and replays a retained `.closed` observation after enable. It also records simulation input while disabled, covering a user choosing simulated close before enabling.

Focused lifecycle command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests.testEnablingReplaysSimulatedClosedStateAfterDisable
```

Observed: exit 0; 1 test executed, 0 failures.

Covering matrix command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review-swiftpm-module-cache \
swift test --filter ProtectionSourceStateTests
```

Observed: exit 0; 6 tests executed, 0 failures.

Full command:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task3-review-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task3-review-swiftpm-module-cache \
swift test
```

Observed: exit 0; 34 tests executed, 0 failures.

### Review self-check

- The lifecycle test fails if the simulation observation is cleared on disable, or if enable does not replay `.closed`.
- Disable still clears every active source and restores exactly once; it preserves only the UI-owned simulation observation needed for reactivation.
- Physical lid and night observations remain unchanged; no deferred Minor finding was addressed.
- `git diff --check` passed.
