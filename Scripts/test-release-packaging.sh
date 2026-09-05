#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
source "$root/Scripts/lib/release-packaging.zsh"

cache_root="${TMPDIR:-/tmp}/lidmute-release-packaging-test-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$cache_root/swift}"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/lidmute-package-policy.XXXXXX")"
fixture="$(cd -P -- "$fixture" && pwd)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/repo/dist" "$fixture/repo/nested"

safe="$(validate_output_path "$fixture/repo" "$fixture/repo/dist/LidMute.app")"
[[ "$safe" == "$fixture/repo/dist/LidMute.app" ]]

for unsafe in "/" "$HOME" "$fixture/repo" "$fixture/repo/dist" \
  "$fixture/repo/LidMute.app" "$fixture/repo/dist/nested/LidMute.app" \
  "$fixture/repo/dist/not-an-app"; do
  if validate_output_path "$fixture/repo" "$unsafe" >/dev/null 2>&1; then
    print -u2 "unexpected safe path: $unsafe"
    exit 1
  fi
done
print "PASS release packaging path policy"

mkdir -p "$fixture/outside" "$fixture/symlinked-repo"
print 'preserve' > "$fixture/outside/sentinel"
ln -s "$fixture/repo/dist" "$fixture/repo/dist-alias"
ln -s "$fixture/outside" "$fixture/repo/dist/Symlink.app"
ln -s "$fixture/outside" "$fixture/symlinked-repo/dist"
for unsafe in "$fixture/repo/dist-alias/Alias.app" \
  "$fixture/repo/dist/Symlink.app" \
  "$fixture/symlinked-repo/dist/Outside.app"; do
  if validate_output_path "${unsafe:h:h}" "$unsafe" >/dev/null 2>&1; then
    print -u2 "unexpected safe symlink path: $unsafe"
    exit 1
  fi
  cleanup_output_bundle "$fixture/repo" "$unsafe" >/dev/null 2>&1 || true
done
[[ "$(<"$fixture/outside/sentinel")" == "preserve" ]]
print "PASS release packaging symlink threat policy"

invalid_root_mkdir_log="$fixture/invalid-root-mkdir.log"
(
  mkdir() {
    print -r -- "$*" > "$invalid_root_mkdir_log"
    return 0
  }
  if validate_output_path "$fixture/missing-repo" "$fixture/repo/dist/InvalidRoot.app" >/dev/null 2>&1; then
    exit 1
  fi
)
[[ ! -e "$invalid_root_mkdir_log" ]]
print "PASS invalid repository root has no filesystem side effects"

mkdir -p "$fixture/no-dist-repo"
if validate_output_path "$fixture/no-dist-repo" "$fixture/no-dist-repo/dist/NoDist.app" >/dev/null 2>&1; then
  print -u2 "unexpected safe path without an existing dist directory"
  exit 1
fi
[[ ! -e "$fixture/no-dist-repo/dist" ]]
print "PASS path validation never creates an unbound dist directory"

[[ "$(read_version_value "$root/Config/Version.plist" CFBundleShortVersionString)" == "0.1.0" ]]
[[ "$(read_version_value "$root/Config/Version.plist" CFBundleVersion)" == "1" ]]
! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$root/Config/LidMuteRelease.entitlements" >/dev/null 2>&1
print "PASS controlled version and release entitlements"

mode="$(resolve_signing_mode "")"
[[ "$mode" == "adhoc" ]]
[[ "$(resolve_signing_mode adhoc)" == "adhoc" ]]
[[ "$(resolve_signing_mode developer-id)" == "developer-id" ]]
if resolve_signing_mode automatic >/dev/null 2>&1; then exit 1; fi
if validate_developer_id_inputs "" "profile" >/dev/null 2>&1; then exit 1; fi
if validate_developer_id_inputs "Developer ID Application: Example (TEAMID)" "" >/dev/null 2>&1; then exit 1; fi
print "PASS deterministic signing mode and credential gates"

grep -Fq -- '--configuration release' "$root/Scripts/make-app-bundle.sh"
grep -Fq '_release_filesystem "$root" create-stage "$app_name"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'sign_adhoc_bundle "$root" "$staged_app"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'sign_developer_id_bundle "$root" "$staged_app" "$LIDMUTE_DEVELOPER_IDENTITY"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'notarize_and_staple "$staged_app" "$LIDMUTE_NOTARY_PROFILE" "$staging"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'install_staged_bundle "$root" "$staged_app" "$app"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'find "$root/Sources/LidMuteApp" "$root/Sources/LidMuteCore" -type f -newer "$binary"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'find "$root/Sources/LidMuteNativeHost" "$root/Sources/LidMuteCore" -type f -newer "$host"' "$root/Scripts/make-app-bundle.sh"
! grep -Fq 'codesign --force --deep --sign' "$root/Scripts/make-app-bundle.sh"
print "PASS release packaging source contract"

incremental_repo="$fixture/incremental-repo"
incremental_scratch="$fixture/incremental-scratch"
incremental_clang_cache="$fixture/incremental-clang-cache"
incremental_swift_cache="$fixture/incremental-swift-cache"
incremental_app="$incremental_repo/dist/Incremental.app"
mkdir -p "$incremental_repo/dist"
cp -p "$root/Package.swift" "$incremental_repo/"
cp -pR "$root/Assets" "$root/Config" "$root/Scripts" "$root/Sources" "$root/Tests" \
  "$root/ChromeExtension" "$incremental_repo/"

run_incremental_package() {
  local output_log="$1"
  LIDMUTE_SIGNING_MODE=adhoc \
  LIDMUTE_SCRATCH_PATH="$incremental_scratch" \
  CLANG_MODULE_CACHE_PATH="$incremental_clang_cache" \
  SWIFTPM_CACHE_PATH="$incremental_swift_cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$incremental_swift_cache" \
  LIDMUTE_APP_PATH="$incremental_app" \
  zsh "$incremental_repo/Scripts/make-app-bundle.sh" >"$output_log" 2>&1
}

run_incremental_package "$fixture/incremental-baseline.log"
incremental_host_binary="$(find "$incremental_scratch" -type f -path '*/release/LidMuteNativeHost' -print -quit)"
[[ -n "$incremental_host_binary" ]]
incremental_build_root="${incremental_host_binary:h}"
incremental_app_binary="$incremental_build_root/LidMuteApp"
[[ -x "$incremental_app_binary" && -x "$incremental_host_binary" ]]

incremental_app_source="$incremental_repo/Sources/LidMuteApp/AppViewModel.swift"
incremental_core_source="$incremental_repo/Sources/LidMuteCore/Models.swift"
incremental_host_source="$incremental_repo/Sources/LidMuteNativeHost/main.swift"
touch "$incremental_app_source"
rm -- "$incremental_app_binary"
if run_incremental_package "$fixture/incremental-app-only.log"; then
  app_only_status=0
else
  app_only_status=$?
fi
[[ "$app_only_status" -eq 0 ]]
grep -Fq 'Created ./Incremental.app' "$fixture/incremental-app-only.log"
print "PASS App-only incremental update is accepted with unchanged NativeHost"

touch "$incremental_core_source"
if run_incremental_package "$fixture/incremental-core-app.log"; then
  core_app_status=0
else
  core_app_status=$?
fi
[[ "$core_app_status" -eq 67 ]]
grep -Fq 'LidMuteApp is older than' "$fixture/incremental-core-app.log"
grep -Fq 'LidMuteCore/Models.swift' "$fixture/incremental-core-app.log"
print "PASS stale Core source is rejected for LidMuteApp"

touch -r "$incremental_app_binary" "$incremental_core_source"
if run_incremental_package "$fixture/incremental-core-host.log"; then
  core_host_status=0
else
  core_host_status=$?
fi
[[ "$core_host_status" -eq 67 ]]
grep -Fq 'LidMuteNativeHost is older than' "$fixture/incremental-core-host.log"
grep -Fq 'LidMuteCore/Models.swift' "$fixture/incremental-core-host.log"
print "PASS stale Core source is rejected for LidMuteNativeHost"

touch -r "$incremental_host_binary" "$incremental_core_source"
touch "$incremental_host_source"
if run_incremental_package "$fixture/incremental-host-only.log"; then
  host_only_status=0
else
  host_only_status=$?
fi
[[ "$host_only_status" -eq 67 ]]
grep -Fq 'LidMuteNativeHost is older than' "$fixture/incremental-host-only.log"
grep -Fq 'LidMuteNativeHost/main.swift' "$fixture/incremental-host-only.log"
print "PASS stale NativeHost source is rejected"

exec {forged_fd}<"$fixture/outside"
(
  export LIDMUTE_DIST_HANDLE_ACTIVE=1
  export LIDMUTE_DIST_FD="$forged_fd"
  export LIDMUTE_DIST_ROOT=.
  if _release_filesystem "$root" create-stage Forged.app >/dev/null 2>&1; then
    print -u2 "forged active dist handle unexpectedly succeeded"
    exit 1
  fi
)
[[ -z "$(find "$fixture/outside" -maxdepth 1 -name '.lidmute-stage.*' -print -quit)" ]]
exec {forged_fd}<&-
dist_stages_before="$(find "$root/dist" -maxdepth 1 -name '.lidmute-stage.*' -print | sort)"
swift "$root/Scripts/release-filesystem.swift" with-dist "$root" /bin/zsh -c '
  set -euo pipefail
  repo="$1"
  fixture_root="$2"
  exec {external_fd}<"$fixture_root/outside"
  export LIDMUTE_DIST_FD="$external_fd"
  cd "$repo/dist"
  source "$repo/Scripts/lib/release-packaging.zsh"
  if _release_filesystem "$repo" create-stage ForgedCanonicalCwd.app; then
    print -u2 "external inherited dist handle unexpectedly succeeded from canonical cwd"
    exit 1
  fi
' zsh "$root" "$fixture"
[[ -z "$(find "$fixture/outside" -maxdepth 1 -name '.lidmute-stage.*' -print -quit)" ]]
[[ "$(find "$root/dist" -maxdepth 1 -name '.lidmute-stage.*' -print | sort)" == "$dist_stages_before" ]]

swift "$root/Scripts/release-filesystem.swift" with-dist "$root" /bin/zsh -c '
  set -euo pipefail
  repo="$1"
  cd ..
  source "$repo/Scripts/lib/release-packaging.zsh"
  if _release_filesystem "$repo" create-stage ForgedCwd.app; then
    print -u2 "canonical inherited handle unexpectedly succeeded from repository cwd"
    exit 1
  fi
' zsh "$root"
[[ "$(find "$root/dist" -maxdepth 1 -name '.lidmute-stage.*' -print | sort)" == "$dist_stages_before" ]]
print "PASS forged active dist handle is rejected"

missing_identity_app="$root/dist/Task11MissingIdentity-${fixture:t}.app"
missing_profile_app="$root/dist/Task11MissingProfile-${fixture:t}.app"
if LIDMUTE_SIGNING_MODE=developer-id LIDMUTE_DEVELOPER_IDENTITY='' \
   LIDMUTE_NOTARY_PROFILE='profile' LIDMUTE_APP_PATH="$missing_identity_app" \
   zsh "$root/Scripts/make-app-bundle.sh" >"$fixture/missing-identity.log" 2>&1; then exit 1; fi
grep -Fq 'LIDMUTE_DEVELOPER_IDENTITY is required' "$fixture/missing-identity.log"
! grep -Fq '本地验收包' "$fixture/missing-identity.log"
[[ ! -e "$missing_identity_app" ]]
cleanup_output_bundle "$root" "$missing_identity_app"

if LIDMUTE_SIGNING_MODE=developer-id \
   LIDMUTE_DEVELOPER_IDENTITY='Developer ID Application: Example (TEAMID)' \
   LIDMUTE_NOTARY_PROFILE='' LIDMUTE_APP_PATH="$missing_profile_app" \
   zsh "$root/Scripts/make-app-bundle.sh" >"$fixture/missing-profile.log" 2>&1; then exit 1; fi
grep -Fq 'LIDMUTE_NOTARY_PROFILE is required' "$fixture/missing-profile.log"
! grep -Fq '本地验收包' "$fixture/missing-profile.log"
[[ ! -e "$missing_profile_app" ]]
cleanup_output_bundle "$root" "$missing_profile_app"
print "PASS Developer ID entry point fails closed without credentials"

cleanup_probe_app="$root/dist/Task11CleanupProbe-${fixture:t}.app"
stages_before="$(find "$root/dist" -maxdepth 1 -name '.lidmute-stage.*' -print | sort)"
if LIDMUTE_SIGNING_MODE=developer-id \
   LIDMUTE_DEVELOPER_IDENTITY='Developer ID Application: Cleanup Probe (INVALIDTEAM)' \
   LIDMUTE_NOTARY_PROFILE='profile' LIDMUTE_APP_PATH="$cleanup_probe_app" \
   zsh "$root/Scripts/make-app-bundle.sh" >"$fixture/signing-failure.log" 2>&1; then exit 1; fi
! grep -Fq '本地验收包' "$fixture/signing-failure.log"
[[ ! -e "$cleanup_probe_app" ]]
stages_after="$(find "$root/dist" -maxdepth 1 -name '.lidmute-stage.*' -print | sort)"
[[ "$stages_after" == "$stages_before" ]]
cleanup_output_bundle "$root" "$cleanup_probe_app"
print "PASS failed Developer ID signing cleans staging without fallback"

[[ -f "$root/Scripts/release-filesystem.swift" ]]
grep -Fq 'with-dist' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'LIDMUTE_DIST_HANDLE_ACTIVE' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'create-stage' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'install_staged_bundle "$root" "$staged_app" "$app"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'renameatx_np' "$root/Scripts/release-filesystem.swift"
grep -Fq 'O_NOFOLLOW' "$root/Scripts/release-filesystem.swift"
grep -Fq 'unlinkat' "$root/Scripts/release-filesystem.swift"
grep -Fq 'flock' "$root/Scripts/release-filesystem.swift"
grep -Fq 'fstatat(AT_FDCWD, "."' "$root/Scripts/release-filesystem.swift"
grep -Fq 'canonicalStatus' "$root/Scripts/release-filesystem.swift"
grep -Fq 'isolated backup' "$root/Scripts/release-filesystem.swift"
! grep -Fq '.lidmute-install.lock' "$root/Scripts/release-filesystem.swift"
! grep -Eq '(^|[[:space:]])(mv|rm)([[:space:]]|$)' "$root/Scripts/lib/release-packaging.zsh"
print "PASS fixed directory handle release source contract"

zsh "$root/Scripts/test-release-filesystem.sh"
