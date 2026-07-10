# LidMute

LidMute prevents sound from the current default built-in output while the Mac lid
is closed. It remains available from the menu bar and keeps a permanent local
event timeline. The bundled Chrome extension adds tab-level evidence for Chrome
audio events, including a tab title, URL, tab ID, and `audible` transition.

## Build and Verify

```zsh
cd /Users/han/temp/workspace/LidMute
chmod +x Scripts/*.sh
Scripts/run-smoke-check.sh
```

This machine's Command Line Tools do not expose XCTest or Swift Testing, so the
repository uses a no-dependency executable behavior suite instead of `swift test`.

## Run

```zsh
CLANG_MODULE_CACHE_PATH=/tmp/lidmute-clang-cache \
swift run --disable-sandbox --scratch-path /tmp/lidmute-build LidMuteApp
```

Turn on the guard, then use **模拟合盖** and **模拟开盖** to verify the state
machine without physically closing the lid. Real lid-state polling occurs every
second through IOKit while the app is running.

## Chrome Tab-Level Logging

1. Open `chrome://extensions`, turn on Developer mode, and click Load unpacked.
2. Select `ChromeExtension` from this repository and copy its generated extension ID.
3. Register the built helper with that ID:

```zsh
Scripts/register-chrome-host.sh /tmp/lidmute-build/arm64-apple-macosx/debug/LidMuteNativeHost EXTENSION_ID
```

4. Keep LidMute running, open a media tab, and inspect the Activity Log. A Chrome
   `audible` transition is recorded with its title, URL, window ID, and tab ID.

The extension requests only `tabs`, `nativeMessaging`, and `storage`. The host
accepts only the extension origin written by the registration script. Chrome
requires you to explicitly enable an extension in Incognito windows; it is off by default.

## Limitations

- The safeguard mutes sound output; it does not pause a video or terminate a process.
- macOS provides process-level audio activity. Exact Chrome tab attribution is
  supplied only while the bundled extension and native host are installed.
- A built-in audio device may be shared by analog headphones on some hardware.
  Verify your hardware route before relying on the guard with wired headphones.
