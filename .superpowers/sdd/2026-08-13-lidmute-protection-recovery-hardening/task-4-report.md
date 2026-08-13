# Task 4 Report: Built-in Audio Resolution and Route Monitoring

## Scope

- Added pure built-in-speaker candidate resolution by UID or current default output.
- Replaced the `AudioControlling` resolution requirement with `resolveBuiltInSpeaker(uid:)`.
- Re-enumerated CoreAudio devices on every resolution and rejected individual devices whose required UID, name, transport, current output data source, or data-source name could not be read.
- Revalidated the saved UID immediately before capture, silence enforcement, or restoration, and used the newly enumerated `AudioObjectID` for the mutation.
- Added a CoreAudio route monitor for default-output and device-list changes. It retains the exact registered blocks, removes them on stop, rolls back a partial start, and coalesces delivery on `MainActor`.
- Kept the existing coordinator call compiling through an `AudioControlling.builtInSpeaker()` compatibility extension because `ProtectionCoordinator.swift` was outside this task's assigned file ownership. The extension forwards to `resolveBuiltInSpeaker(uid: nil)`.

## TDD Evidence

### RED

Command (run outside the nested sandbox because SwiftPM's manifest sandbox could not initialize inside it):

```text
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task4-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task4-swiftpm-module-cache \
swift test --filter AudioDeviceResolutionTests
```

Observed result:

```text
Test Case '...testExplicitUIDFindsBuiltInSpeakerWhenExternalRouteIsDefault' failed
XCTAssertEqual failed: ("nil") is not equal to ("Optional(11)")
Executed 3 tests, with 1 failure (0 unexpected)
```

This was the expected behavior failure from the declarations-only resolver. The two rejection tests already passed because the placeholder returned `nil`.

An earlier attempt did not count as RED: it stopped during manifest compilation because `/Users/han/.cache/clang/ModuleCache` was not writable. No test executed in that attempt.

### GREEN

Focused command:

```text
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task4-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task4-swiftpm-module-cache \
swift test --filter AudioDeviceResolutionTests
```

Observed result:

```text
Test Suite 'AudioDeviceResolutionTests' passed
Executed 3 tests, with 0 failures (0 unexpected)
```

Independent review found that the original impostor fixture made both transport and data-source classification invalid, so it could not detect deletion of only the data-source guard. A separate internal-transport/non-speaker fixture was then added. With the production data-source guard intentionally removed, the focused suite produced the expected second RED:

```text
testMatchingUIDRejectsInternalTransportWithoutSpeakerDataSource
XCTAssertNil failed: "AudioDevice(id: 17, uid: \"built-in-a\", ...)"
Executed 4 tests, with 1 failure (0 unexpected)
```

After restoring the guard, the focused suite passed 4/4.

Full regression command:

```text
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-task4-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/lidmute-task4-swiftpm-module-cache \
swift test
```

Observed result:

```text
Test Suite 'All tests' passed
Executed 39 tests, with 0 failures (0 unexpected)
```

## Packaging Verification

Command:

```text
zsh Scripts/make-app-bundle.sh
```

Observed result:

```text
PASS visual principle source checks
Build complete!
Created /Users/han/temp/workspace/LidMute/dist/LidMute.app
```

Bundle executable checks passed for:

```text
dist/LidMute.app/Contents/MacOS/LidMute
dist/LidMute.app/Contents/MacOS/LidMuteNativeHost
```

## Test Quality / Mutation Check

- Returning only the default route breaks the explicit-UID test.
- Accepting an external default route breaks the nil-UID rejection test.
- Matching UID without internal transport and speaker data-source classification breaks the impostor rejection test.
- Keeping internal transport but removing the speaker data-source guard breaks the dedicated non-speaker rejection test.
- Resolver expectations are literal IDs or `nil`; they do not reuse production resolver logic.

## Independent Review

The independent review identified two route-monitor lifecycle defects: queued callbacks could survive stop/partial-start failure, and a failed rollback removal could lose cleanup state. The monitor now gates every callback and coalesced delivery on an active state, tracks each listener registration independently, and preserves a failed-removal registration for a later cleanup retry. The review also prompted the separate data-source mutation test described above.

## Not Tested

- Physical route hot-swap on a MacBook.
- Live CoreAudio listener delivery/removal against physical hardware.
