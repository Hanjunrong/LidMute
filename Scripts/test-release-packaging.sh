#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
source "$root/Scripts/lib/release-packaging.zsh"

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
grep -Fq 'mktemp -d "$dist/.lidmute-stage.XXXXXX"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'sign_adhoc_bundle "$root" "$staged_app"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'sign_developer_id_bundle "$root" "$staged_app" "$LIDMUTE_DEVELOPER_IDENTITY"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'notarize_and_staple "$staged_app" "$LIDMUTE_NOTARY_PROFILE" "$staging"' "$root/Scripts/make-app-bundle.sh"
grep -Fq 'install_staged_bundle "$root" "$staged_app" "$app"' "$root/Scripts/make-app-bundle.sh"
! grep -Fq 'codesign --force --deep --sign' "$root/Scripts/make-app-bundle.sh"
print "PASS release packaging source contract"

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
