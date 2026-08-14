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
cleanup_fixture() {
  for pid in "${holder_pid:-}" "${second_pid:-}"; do
    [[ "$pid" == <-> ]] || continue
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf -- "$fixture"
}
trap cleanup_fixture EXIT

wait_bounded() {
  local pid="$1" label="$2"
  for ((i = 0; i < 500; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid"; then
        return 0
      fi
      return $?
    fi
    sleep 0.01
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  print -u2 "$label did not exit within bounded wait"
  return 1
}

mkdir -p "$fixture/repo/dist" "$fixture/external"
print 'preserve' > "$fixture/external/sentinel"

coproc swift "$helper" with-dist "$fixture/repo" /bin/zsh -c '
  set -euo pipefail
  setopt NO_BG_NICE
  helper="$1"
  print READY
  read -r -t 5 _
  stage="$(swift "$helper" create-stage "$LIDMUTE_DIST_FD" Race.app)"
  print -r -- "$stage"
  read -r -t 5 _
  swift "$helper" remove "$LIDMUTE_DIST_FD" stage "$stage"
  print DONE
' zsh "$helper"
holder_pid="$!"
IFS= read -r -t 5 -p ready
[[ "$ready" == "READY" ]]
mv -- "$fixture/repo/dist" "$fixture/repo/original-dist"
ln -s "$fixture/external" "$fixture/repo/dist"
print -p -- GO
IFS= read -r -t 5 -p swapped_stage
print -p -- CLEAN
IFS= read -r -t 5 -p cleaned
[[ "$cleaned" == DONE ]]
wait_bounded "$holder_pid" "parent-symlink holder"
holder_pid=""

[[ ! -e "$fixture/repo/original-dist/$swapped_stage" ]]
[[ "$(<"$fixture/external/sentinel")" == "preserve" ]]
[[ -z "$(find "$fixture/external" -mindepth 1 ! -name sentinel -print -quit)" ]]
unlink "$fixture/repo/dist"
mv -- "$fixture/repo/original-dist" "$fixture/repo/dist"
print "PASS fixed dist handle resists parent symlink swap"

holder_fifo="$fixture/holder.release"
second_fifo="$fixture/second.release"
holder_output="$fixture/holder.output"
second_output="$fixture/second.output"
holder_error="$fixture/holder.error"
second_error="$fixture/second.error"
mkfifo "$holder_fifo" "$second_fifo"

# Keep one independent read/write descriptor open for each FIFO. This avoids
# zsh's global coprocess input/output descriptors being rebound when the
# second process starts, and gives every wait a bounded, explicit barrier.
exec {holder_ctl}<>"$holder_fifo"
exec {second_ctl}<>"$second_fifo"

swift "$helper" with-dist "$fixture/repo" /bin/zsh -c '
  set -euo pipefail
  helper="$1"
  swift "$helper" hold-lock "$LIDMUTE_DIST_FD"
' zsh "$helper" <&$holder_ctl >"$holder_output" 2>"$holder_error" &
holder_pid="$!"

for ((i = 0; i < 200; i++)); do
  grep -Fqx LOCKED "$holder_output" 2>/dev/null && break
  if ! kill -0 "$holder_pid" 2>/dev/null; then
    cat "$holder_error" >&2
    exit 1
  fi
  sleep 0.01
done
grep -Fqx LOCKED "$holder_output"

swift "$helper" with-dist "$fixture/repo" /bin/zsh -c '
  set -euo pipefail
  helper="$1"
  swift "$helper" hold-lock "$LIDMUTE_DIST_FD"
  print SECOND-LOCKED
' zsh "$helper" <&$second_ctl >"$second_output" 2>"$second_error" &
second_pid="$!"

for ((i = 0; i < 100; i++)); do
  if grep -Fqx LOCKED "$second_output" 2>/dev/null; then
    print -u2 "second installer acquired the lock while the first held it"
    exit 1
  fi
  if ! kill -0 "$second_pid" 2>/dev/null; then
    cat "$second_error" >&2
    exit 1
  fi
  sleep 0.01
done

print -u$holder_ctl -- RELEASE
for ((i = 0; i < 200; i++)); do
  if ! kill -0 "$holder_pid" 2>/dev/null; then
    wait "$holder_pid"
    holder_pid=""
    break
  fi
  sleep 0.01
done
[[ -z "$holder_pid" ]] || {
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  print -u2 "holder did not release within bounded wait"
  exit 1
}

for ((i = 0; i < 200; i++)); do
  grep -Fqx LOCKED "$second_output" 2>/dev/null && break
  if ! kill -0 "$second_pid" 2>/dev/null; then
    cat "$second_error" >&2
    exit 1
  fi
  sleep 0.01
done
grep -Fqx LOCKED "$second_output"
print -u$second_ctl -- RELEASE
for ((i = 0; i < 200; i++)); do
  if ! kill -0 "$second_pid" 2>/dev/null; then
    wait "$second_pid"
    second_pid=""
    break
  fi
  sleep 0.01
done
[[ -z "$second_pid" ]] || {
  kill "$second_pid" 2>/dev/null || true
  wait "$second_pid" 2>/dev/null || true
  print -u2 "second holder did not exit within bounded wait"
  exit 1
}
exec {holder_ctl}>&-
exec {second_ctl}>&-
print "PASS independent dist lock blocks a concurrent installer"

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

  wait_bounded() {
    local pid="$1" label="$2"
    for ((i = 0; i < 500; i++)); do
      if ! kill -0 "$pid" 2>/dev/null; then
        if wait "$pid"; then
          return 0
        fi
        return $?
      fi
      sleep 0.01
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    print -u2 "$label did not exit within bounded wait"
    return 1
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
  wait_bounded "$pid_a" "race installer A"
  wait_bounded "$pid_b" "race installer B"
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

cleanup_error_log="$fixture/cleanup-error.log"
swift "$helper" with-dist "$fixture/repo" /bin/zsh -c '
  set -euo pipefail
  helper="$1"
  fd="$LIDMUTE_DIST_FD"
  dist="${LIDMUTE_DIST_ROOT:-.}"

  make_app() {
    local app="$1" marker="$2"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Resources/Nested"
    print executable > "$app/Contents/MacOS/LidMute"
    print executable > "$app/Contents/MacOS/LidMuteNativeHost"
    chmod +x "$app/Contents/MacOS/LidMute" "$app/Contents/MacOS/LidMuteNativeHost"
    print plist > "$app/Contents/Info.plist"
    print local-adhoc > "$app/Contents/Resources/BuildChannel.txt"
    print -r -- "$marker" > "$app/Contents/Resources/TestMarker.txt"
    print extra-a > "$app/Contents/Resources/Nested/a.txt"
    print extra-b > "$app/Contents/Resources/Nested/b.txt"
  }

  old_stage="$(swift "$helper" create-stage "$fd" Cleanup.app)"
  make_app "$dist/$old_stage/Cleanup.app" old
  swift "$helper" install "$fd" "$old_stage" Cleanup.app Cleanup.app
  swift "$helper" remove "$fd" stage "$old_stage"
  new_stage="$(swift "$helper" create-stage "$fd" Cleanup.app)"
  make_app "$dist/$new_stage/Cleanup.app" new
  if LIDMUTE_TEST_FAIL_UNLINK_AFTER=1 swift "$helper" install "$fd" "$new_stage" Cleanup.app Cleanup.app; then
    print -u2 "injected backup cleanup failure unexpectedly succeeded"
    exit 1
  fi
  [[ "$(<"$dist/Cleanup.app/Contents/Resources/TestMarker.txt")" == new ]]
  [[ ! -e "$dist/Cleanup.app/Cleanup.app" ]]
  backup_count="$(find "$dist" -maxdepth 1 -name ".lidmute-backup.*" -type d | wc -l | tr -d " ")"
  [[ "$backup_count" == 1 ]]
  swift "$helper" remove "$fd" stage "$new_stage"
  backup_name="$(find "$dist" -maxdepth 1 -name ".lidmute-backup.*" -type d -print -quit)"
  swift "$helper" remove "$fd" backup "${backup_name:t}"
  swift "$helper" remove "$fd" app Cleanup.app
' zsh "$helper" >"$cleanup_error_log" 2>&1
grep -Fq 'verified destination installed; isolated backup' "$cleanup_error_log"
print "PASS backup cleanup failure preserves verified destination"
