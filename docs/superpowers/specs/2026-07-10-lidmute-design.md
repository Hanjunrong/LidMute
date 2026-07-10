# LidMute Design

## Goal

Build a native macOS menu bar application that prevents the MacBook's built-in
speakers from producing sound while the lid is closed, then restores the prior
volume while keeping the speaker muted when the lid opens. It must retain detailed local records of
processes that output audio during the protected interval.

## Chosen Approach

LidMute is a SwiftUI and AppKit application backed by public IOKit and CoreAudio
APIs. A clamshell observer receives the lid state from `IOPMrootDomain`. An
audio guard targets only the built-in speaker output device; it saves the
device's prior mute and volume state, mutes it on close, and restores the prior
volume while keeping mute enabled on open. The guard re-applies the mute whenever the device becomes active
or an audio process begins output while protection is active.

The app uses CoreAudio process objects to report process-level audio activity.
It records a process name, PID, bundle identifier, executable path, launch
time, output device identifiers, and device volume/mute state. For Chrome, a
bundled Manifest V3 extension supplements the system record with tab-level
evidence: tab ID, window ID, title, committed URL, audible transition, muted
state, and capture time. The extension uses Chrome Native Messaging through a
separate `LidMuteNativeHost` executable that validates and appends framed JSON
messages to an application-private local inbox file. The running app polls that
inbox, so speaker protection remains independent if Chrome is unavailable.

## User Experience

- The main window is a compact, polished control panel with translucent material,
  colored light fields, soft highlights, layered cards, and restrained motion.
  The visual direction is a warm liquid-glass panel rather than a generic dark
  dashboard.
- The central switch is the authoritative control. When enabled, the menu bar
  icon remains active after the main window is closed.
- The menu bar offers Enable/Disable, Open LidMute, Open Activity Log, and Quit.
- The status card states one of: inactive, armed with lid open, actively
  protecting the built-in speakers, or unavailable because no built-in output
  device is present.
- The event log is retained indefinitely in the app's Application Support
  directory. A single visible Clear Log action asks for confirmation and then
  removes all locally stored events.
- A diagnostics section exposes simulation controls for lid closed/open and a
  live snapshot of the target audio device. Simulation never changes the real
  lid state; it exercises the same protection state machine.
- The Chrome card reports whether the bundled extension and its Native Messaging
  bridge are connected. It explains that tab-level events are unavailable until
  the user loads the extension and runs the provided bridge-registration step.

## Protection Rules

1. Only a built-in speaker device is targeted. Headphones, Bluetooth devices,
   HDMI/DisplayPort audio, and other external outputs are never muted by LidMute.
2. On an armed lid-close event, capture the built-in speaker's current mute and
   scalar volume values before forcing mute. If mute is unsupported, set volume
   to zero and record that fallback.
3. While the lid remains closed, monitor CoreAudio output-process state and the
   target device's running state. Every newly observed active audio process is
   logged and triggers another mute enforcement.
4. On an armed lid-open event, restore the volume captured for the active
   protection interval while keeping the built-in speaker muted. Never overwrite
   a user state change made after opening.
5. When the user disables the guard, fully restore the mute and volume state
   captured before the first protected interval, including after a lid-open.
6. If the target device changes, disappears, or reports no controllable mute or
   volume property, preserve the guard state, emit an explicit diagnostic event,
   and show the error in the UI.
7. During protection, a Chrome tab that changes to `audible: true` emits a
   tab-level event immediately. The event is correlated with an active Chrome
   CoreAudio process when one is seen in the same short correlation window. If
   CoreAudio does not observe Chrome, the tab event remains valid but is marked
   `browser-observed-only` rather than falsely claiming a system-output match.

## Event Record

Each record has a stable UUID and includes:

- wall-clock timestamp and monotonic capture sequence;
- event kind: lid closed, lid opened, protection armed, mute enforced, audio
  process detected, device change, restoration, error, or simulation;
- rule decision and reason;
- process display name, PID, bundle identifier, executable path, and launch
  date when available;
- target device UID, name, transport type, current mute value, current volume,
  and whether the volume-zero fallback was used;
- whether the process was newly active or already active when the lid closed;
- for Chrome: extension session ID, tab ID, window ID, tab index, title, URL,
  audible transition, tab-muted state, whether the tab is active or pinned, and
  correlation status with the system Chrome process;
- a human-readable detail string for the activity-log UI and copy action.

Records are persisted as JSON Lines behind a small `EventStore` boundary so the
retention policy can later change without modifying audio-control code.

## Architecture

`ProtectionCoordinator` is the state machine and the only type allowed to
combine lid events, audio events, and muting actions. `LidStateMonitoring` is
an IOKit adapter. `AudioControlling` is a CoreAudio adapter for device discovery,
mute/volume reads and writes, and process snapshots. `EventStoring` writes and
loads records. `ChromeBridgeServer` accepts validated tab events from the local
native host. The MV3 service worker observes `tabs.onUpdated`, `tabs.onRemoved`,
and initial tab snapshots, then forwards Chrome events through a persistent
Native Messaging port. SwiftUI view models consume coordinator snapshots and
events but do not call IOKit or CoreAudio directly.

State transitions are serialised on the main actor. CoreAudio and IOKit
callbacks submit immutable events to the coordinator; they do not synchronously
write files or mutate views. This avoids re-entrant mute cycles and keeps the
event ordering reproducible in tests.

## Testing and Verification

- Unit tests cover the protection state machine: close captures/mutes, open
  restores, a new output process re-enforces, unsupported mute falls back to
  zero volume, and a missing built-in device produces an error event.
- Adapter tests use fakes to verify CoreAudio property selection and that
  external devices are never targeted.
- Persistence tests cover append, reload, malformed-record recovery, and clear.
- Chrome-bridge tests cover frame validation, a newly audible tab, a muted tab,
  a tab removal, missing Chrome connection, and process/tab correlation.
- Extension tests cover tab-event serialization and recovery after a Native
  Messaging port disconnects.
- A manual smoke checklist verifies the UI, menu bar persistence, simulation
  buttons, guard state, event log, and real audio-device behavior.
- The app must compile using `swift build` on this machine, which has macOS
  Command Line Tools and Swift 6.3.3 but not full Xcode.

## Constraints

- macOS only; target the current macOS 26 SDK.
- Use public IOKit, CoreAudio, SwiftUI, AppKit, and Foundation APIs only.
- No network services, telemetry, external dependencies, virtual audio drivers,
  or elevated privileges.
- The bundled Chrome extension declares `tabs`, `nativeMessaging`, and `storage` only. The
  host manifest's `allowed_origins` contains only the generated extension ID.
- Chrome does not automatically grant extensions Incognito access. If Incognito
  tab evidence is required, the user must enable the extension's "Allow in
  Incognito" setting in Chrome; the default is to omit those tabs.
- The app is a foreground-capable menu bar app. It continues running after its
  main window closes, but auto-launch at login is out of scope for the first
  version because it requires installed and signed app-bundle deployment.
