# Task 1 Report

## Status

DONE_WITH_CONCERNS

## Changes

- Replaced the `LidMuteCoreBehaviorTests` executable product/target with the standard SwiftPM `LidMuteCoreTests` `.testTarget`.
- Migrated all 30 existing behavior checks into discovered Swift Testing `@Test` cases in `Tests/LidMuteCoreTests/ExistingBehaviorTests.swift`.
- Moved reusable `MemoryEventStore`, `FakeAudioController`, and `FakeAudioError` into `Tests/LidMuteCoreTests/TestDoubles.swift`.
- Deleted the old executable harness at `Tests/LidMuteCoreBehavior/main.swift`.
- Changed the smoke test and repository test contract to use `swift test`.

## RED

Command:

```bash
swift test --filter ExistingBehaviorTests/testNightScheduleHandlesBeijingTimeAcrossMidnight
```

Observed: exit 1. The repository had no standard test target; the local default CLT additionally reported a module-cache permission error and a Swift 6.3.3/compiler versus macOS 26.5 SDK 6.3.2 mismatch.

## GREEN attempt

Commands:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task1-clang \
SWIFTPM_CACHE_PATH=/tmp/lidmute-task1-swiftpm \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift test --disable-sandbox --scratch-path /tmp/lidmute-task1-build26 \
  --filter ExistingBehaviorTests.testNightScheduleHandlesBeijingTimeAcrossMidnight
```

Observed: exit 1 because this Command Line Tools installation exposes neither an importable `XCTest` nor `Testing` module. `Testing.framework` exists, but its Swift module is absent. Therefore no Swift GREEN claim is made.

Available verification:

- `swiftc -frontend -parse Tests/LidMuteCoreTests/ExistingBehaviorTests.swift Tests/LidMuteCoreTests/TestDoubles.swift`: exit 0.
- `git diff --check`: exit 0.
- `zsh -n Scripts/run-smoke-check.sh`: exit 0.
- Test inventory: exactly 30 `@Test` cases.
- `node --test ChromeExtension/service-worker.test.mjs`: 2/2 passed.
- `bash Scripts/check-visual-principles.sh`: passed.
- `swift package dump-package` with isolated cache and explicit SDK reports `LidMuteCoreTests` with type `test`.

## Self-review

- All former harness functions are represented by one discovered test each.
- Assertions remain behavior-facing; fake collaborators retain the prior counters/state and add the reusable mutation list required by the plan.
- No production source file changed.
- Canonical package/smoke commands now agree on `swift test`.

## Commit

`67840be` (`test: adopt standard SwiftPM test target`)

## Concern

Full Swift GREEN and smoke packaging cannot run until the local Apple Command Line Tools installation provides an importable test framework module (or a complete matching Xcode toolchain is selected).
