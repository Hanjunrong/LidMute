#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/lidmute-clang-cache"
export SWIFTPM_CACHE_PATH="${TMPDIR:-/tmp}/lidmute-swiftpm-cache"
scratch="${TMPDIR:-/tmp}/lidmute-build"

swift build --disable-sandbox --scratch-path "$scratch"
swift run --disable-sandbox --scratch-path "$scratch" LidMuteCoreBehaviorTests
node --test ChromeExtension/service-worker.test.mjs
bin_path="$(swift build --disable-sandbox --scratch-path "$scratch" --show-bin-path)"
test -x "$bin_path/LidMuteApp"
test -x "$bin_path/LidMuteNativeHost"
test -f ChromeExtension/manifest.json
! grep -q '"scripting"' ChromeExtension/manifest.json
! grep -q '"<all_urls>"' ChromeExtension/manifest.json
LIDMUTE_SCRATCH_PATH="$scratch" zsh Scripts/make-app-bundle.sh
LIDMUTE_SCRATCH_PATH="$scratch" zsh Scripts/make-app-bundle.sh
test -f dist/LidMute.app/Contents/Resources/AppIcon.icns
file dist/LidMute.app/Contents/Resources/AppIcon.icns | grep -q "Mac OS X icon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' dist/LidMute.app/Contents/Info.plist)" = "AppIcon"
test -f dist/LidMute.app/Contents/Resources/ChromeExtension/manifest.json
test ! -e dist/LidMute.app/Contents/Resources/ChromeExtension/ChromeExtension
! grep -q "应用时间" Sources/LidMuteApp/ContentView.swift
grep -q "private struct SimulationCard" Sources/LidMuteApp/ContentView.swift
grep -Fq ".disabled(!model.isEnabled)" Sources/LidMuteApp/ContentView.swift
print "PASS LidMute smoke check"
