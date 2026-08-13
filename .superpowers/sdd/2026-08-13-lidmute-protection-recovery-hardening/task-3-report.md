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

## Commit

Implementation commit recorded after this report using the Task 3-required message and OMC trailers.

## Concerns

None.
