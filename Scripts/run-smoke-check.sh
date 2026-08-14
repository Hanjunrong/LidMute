#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/lidmute-clang-cache"
export SWIFTPM_CACHE_PATH="${TMPDIR:-/tmp}/lidmute-swiftpm-cache"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lidmute-smoke.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

swift build --disable-sandbox --scratch-path "$scratch"
swift test --disable-sandbox --scratch-path "$scratch"
node --test ChromeExtension/service-worker.test.mjs
bin_path="$(swift build --disable-sandbox --scratch-path "$scratch" --show-bin-path)"
test -x "$bin_path/LidMuteApp"
test -x "$bin_path/LidMuteNativeHost"
test -f ChromeExtension/manifest.json
! grep -q '"scripting"' ChromeExtension/manifest.json
! grep -q '"<all_urls>"' ChromeExtension/manifest.json
grep -Fq 'heartbeatInterval: 2' Sources/LidMuteNativeHost/main.swift
grep -Fq 'defer { heartbeatWriter.stopAndRemove() }' Sources/LidMuteNativeHost/main.swift
packaging_log="$scratch/packaging.log"
LIDMUTE_SIGNING_MODE=adhoc LIDMUTE_SCRATCH_PATH="$scratch" \
  LIDMUTE_APP_PATH="$root/dist/LidMute.app" zsh Scripts/make-app-bundle.sh 2>&1 | tee "$packaging_log"
app="$root/dist/LidMute.app"
[[ "$(<"$app/Contents/Resources/BuildChannel.txt")" == "local-adhoc" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Version.plist)" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Config/Version.plist)" ]]
codesign --verify --deep --strict --verbose=2 "$app"
! codesign -d --entitlements :- "$app" 2>&1 | grep -q 'get-task-allow'
file "$app/Contents/MacOS/LidMute" | grep -q 'Mach-O'
grep -Fq '本地验收包，不可公开分发' "$packaging_log"
grep -Fq 'configuration: release' "$packaging_log"
test -f "$app/Contents/Resources/AppIcon.icns"
file "$app/Contents/Resources/AppIcon.icns" | grep -q "Mac OS X icon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" = "AppIcon"
test -f "$app/Contents/Resources/ChromeExtension/manifest.json"
test ! -e "$app/Contents/Resources/ChromeExtension/ChromeExtension"
test "$(find "$app/Contents/Resources" -type d -name ChromeExtension | wc -l | tr -d ' ')" = "1"
! grep -q "应用时间" Sources/LidMuteApp/ContentView.swift
grep -q "private struct SimulationCard" Sources/LidMuteApp/ContentView.swift
grep -Fq ".disabled(!model.isEnabled)" Sources/LidMuteApp/ContentView.swift
print "PASS LidMute smoke check"
