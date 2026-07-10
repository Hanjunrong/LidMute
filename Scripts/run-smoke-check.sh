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
LIDMUTE_BUILD_ROOT="$bin_path" zsh Scripts/make-app-bundle.sh
LIDMUTE_BUILD_ROOT="$bin_path" zsh Scripts/make-app-bundle.sh
test -f dist/LidMute.app/Contents/Resources/AppIcon.icns
file dist/LidMute.app/Contents/Resources/AppIcon.icns | grep -q "Mac OS X icon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' dist/LidMute.app/Contents/Info.plist)" = "AppIcon"
test -f dist/LidMute.app/Contents/Resources/ChromeExtension/manifest.json
test ! -e dist/LidMute.app/Contents/Resources/ChromeExtension/ChromeExtension
print "PASS LidMute smoke check"
