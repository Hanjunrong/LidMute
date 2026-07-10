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
test -x "$scratch/arm64-apple-macosx/debug/LidMuteApp"
test -x "$scratch/arm64-apple-macosx/debug/LidMuteNativeHost"
test -f ChromeExtension/manifest.json
print "PASS LidMute smoke check"
