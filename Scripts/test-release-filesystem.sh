#!/bin/zsh
set -euo pipefail
setopt NO_BG_NICE

root="${0:A:h:h}"
helper="$root/Scripts/release-filesystem.swift"
cache_root="${TMPDIR:-/tmp}/lidmute-release-filesystem-test-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$cache_root/swift}"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/lidmute-release-fs.XXXXXX")"
fixture="$(cd -P -- "$fixture" && pwd)"
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/repo/dist" "$fixture/external"
print 'preserve' > "$fixture/external/sentinel"

coproc swift "$helper" with-dist "$fixture/repo" /bin/zsh -c '
  set -euo pipefail
  setopt NO_BG_NICE
  helper="$1"
  print READY
  read -r _
  stage="$(swift "$helper" create-stage "$LIDMUTE_DIST_FD" Race.app)"
  print -r -- "$stage"
  read -r _
  swift "$helper" remove "$LIDMUTE_DIST_FD" stage "$stage"
  print DONE
' zsh "$helper"
holder_pid="$!"
IFS= read -r -p ready
[[ "$ready" == "READY" ]]
mv -- "$fixture/repo/dist" "$fixture/repo/original-dist"
ln -s "$fixture/external" "$fixture/repo/dist"
print -p -- GO
IFS= read -r -p swapped_stage
print -p -- CLEAN
IFS= read -r -p cleaned
[[ "$cleaned" == DONE ]]
wait "$holder_pid"

[[ ! -e "$fixture/repo/original-dist/$swapped_stage" ]]
[[ "$(<"$fixture/external/sentinel")" == "preserve" ]]
[[ -z "$(find "$fixture/external" -mindepth 1 ! -name sentinel -print -quit)" ]]
unlink "$fixture/repo/dist"
mv -- "$fixture/repo/original-dist" "$fixture/repo/dist"
print "PASS fixed dist handle resists parent symlink swap"

swift "$helper" with-dist "$fixture/repo" /bin/zsh -c '
  set -euo pipefail
  setopt NO_BG_NICE
  helper="$1"
  fd="$LIDMUTE_DIST_FD"
  dist="${LIDMUTE_DIST_ROOT:-.}"

  make_app() {
    local app="$1" marker="$2"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    print executable > "$app/Contents/MacOS/LidMute"
    print executable > "$app/Contents/MacOS/LidMuteNativeHost"
    chmod +x "$app/Contents/MacOS/LidMute" "$app/Contents/MacOS/LidMuteNativeHost"
    print plist > "$app/Contents/Info.plist"
    print local-adhoc > "$app/Contents/Resources/BuildChannel.txt"
    print -r -- "$marker" > "$app/Contents/Resources/TestMarker.txt"
  }

  old_stage="$(swift "$helper" create-stage "$fd" LidMute.app)"
  make_app "$dist/$old_stage/LidMute.app" old
  swift "$helper" install "$fd" "$old_stage" LidMute.app LidMute.app
  swift "$helper" remove "$fd" stage "$old_stage"

  mkdir "$dist/.lidmute-backup.preoccupied"
  print preserve > "$dist/.lidmute-backup.preoccupied/sentinel"
  new_stage="$(swift "$helper" create-stage "$fd" LidMute.app)"
  make_app "$dist/$new_stage/LidMute.app" new

  if swift "$helper" install "$fd" "$new_stage" LidMute.app LidMute.app \
      .lidmute-backup.preoccupied strict; then
    print -u2 "strict backup collision unexpectedly succeeded"
    exit 1
  fi
  [[ "$(<"$dist/LidMute.app/Contents/Resources/TestMarker.txt")" == old ]]
  [[ "$(<"$dist/$new_stage/LidMute.app/Contents/Resources/TestMarker.txt")" == new ]]
  [[ "$(<"$dist/.lidmute-backup.preoccupied/sentinel")" == preserve ]]

  swift "$helper" install "$fd" "$new_stage" LidMute.app LidMute.app \
    .lidmute-backup.preoccupied
  [[ "$(<"$dist/LidMute.app/Contents/Resources/TestMarker.txt")" == new ]]
  [[ ! -e "$dist/$new_stage/LidMute.app" ]]
  [[ ! -e "$dist/LidMute.app/LidMute.app" ]]
  [[ "$(<"$dist/.lidmute-backup.preoccupied/sentinel")" == preserve ]]
  swift "$helper" remove "$fd" stage "$new_stage"
  swift "$helper" remove "$fd" backup .lidmute-backup.preoccupied

  occupied_stage="$(swift "$helper" create-stage "$fd" Preoccupied.app)"
  make_app "$dist/$occupied_stage/Preoccupied.app" candidate
  mkdir "$dist/Preoccupied.app"
  if swift "$helper" install "$fd" "$occupied_stage" Preoccupied.app Preoccupied.app; then
    print -u2 "invalid preoccupied destination unexpectedly succeeded"
    exit 1
  fi
  [[ -d "$dist/$occupied_stage/Preoccupied.app" ]]
  [[ -d "$dist/Preoccupied.app" ]]
  [[ ! -e "$dist/Preoccupied.app/Preoccupied.app" ]]
  swift "$helper" remove "$fd" app Preoccupied.app
  swift "$helper" remove "$fd" stage "$occupied_stage"

  stage_a="$(swift "$helper" create-stage "$fd" Race.app)"
  stage_b="$(swift "$helper" create-stage "$fd" Race.app)"
  make_app "$dist/$stage_a/Race.app" A
  make_app "$dist/$stage_b/Race.app" B
  swift "$helper" install "$fd" "$stage_a" Race.app Race.app &
  pid_a="$!"
  swift "$helper" install "$fd" "$stage_b" Race.app Race.app &
  pid_b="$!"
  wait "$pid_a"
  wait "$pid_b"
  marker="$(<"$dist/Race.app/Contents/Resources/TestMarker.txt")"
  [[ "$marker" == A || "$marker" == B ]]
  [[ ! -e "$dist/Race.app/Race.app" ]]
  [[ ! -e "$dist/$stage_a/Race.app" && ! -e "$dist/$stage_b/Race.app" ]]
  swift "$helper" remove "$fd" stage "$stage_a"
  swift "$helper" remove "$fd" stage "$stage_b"
  swift "$helper" remove "$fd" app Race.app
  [[ -z "$(find "$dist" -maxdepth 1 -name ".lidmute-backup.*" -print -quit)" ]]
' zsh "$helper"
print "PASS exclusive install handles destination and backup races"
