#!/bin/zsh

validate_output_path() {
  local repo_root="$1" candidate="$2"
  local canonical_root dist canonical_dist parent base canonical_parent resolved
  canonical_root="$(cd -P -- "$repo_root" && pwd)" || return 64
  dist="$canonical_root/dist"
  [[ -d "$dist" && ! -L "$dist" ]] || return 64
  canonical_dist="$(cd -P -- "$dist" && pwd)" || return 64
  parent="${candidate:h}"
  base="${candidate:t}"
  canonical_parent="$(cd -P -- "$parent" 2>/dev/null && pwd)" || return 64
  [[ "$dist" == "$canonical_dist" && ! -L "$dist" ]] || return 64
  [[ "$canonical_parent" == "$canonical_dist" ]] || return 64
  [[ "$parent" == "$canonical_dist" && ! -L "$parent" ]] || return 64
  [[ "$base" == *.app && "$base" != ".app" ]] || return 64
  resolved="$canonical_parent/$base"
  [[ "$resolved" != "/" && "$resolved" != "$HOME" && "$resolved" != "$canonical_root" ]] || return 64
  [[ ! -L "$resolved" ]] || return 64
  print -r -- "$resolved"
}

read_version_value() {
  local plist="$1" key="$2" value
  [[ "$key" == "CFBundleShortVersionString" || "$key" == "CFBundleVersion" ]] || return 65
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || return 65
  if [[ "$key" == "CFBundleShortVersionString" ]]; then
    [[ "$value" == <->.<->.<-> ]] || return 65
  else
    [[ "$value" == <-> && "$value" -ge 1 ]] || return 65
  fi
  print -r -- "$value"
}

resolve_signing_mode() {
  case "${1:-adhoc}" in
    adhoc|developer-id) print -r -- "${1:-adhoc}" ;;
    *) print -u2 "LIDMUTE_SIGNING_MODE must be adhoc or developer-id"; return 64 ;;
  esac
}

validate_developer_id_inputs() {
  local identity="$1" profile="$2" identities
  [[ -n "$identity" ]] || {
    print -u2 "LIDMUTE_DEVELOPER_IDENTITY is required"
    return 64
  }
  [[ -n "$profile" ]] || {
    print -u2 "LIDMUTE_NOTARY_PROFILE is required"
    return 64
  }
  [[ "$identity" == "Developer ID Application: "* ]] || {
    print -u2 "LIDMUTE_DEVELOPER_IDENTITY must be an exact Developer ID Application identity"
    return 64
  }
  if [[ "${LIDMUTE_TEST_SKIP_IDENTITY_LOOKUP:-0}" != "1" ]]; then
    identities="$(security find-identity -v -p codesigning)" || return 64
    print -r -- "$identities" | grep -Fq -- "\"$identity\"" || {
      print -u2 "LIDMUTE_DEVELOPER_IDENTITY was not found exactly in the codesigning keychain"
      return 64
    }
  fi
}

_release_filesystem_script() {
  local repo_root="$1"
  [[ -f "$repo_root/Scripts/release-filesystem.swift" ]] || return 69
  print -r -- "$repo_root/Scripts/release-filesystem.swift"
}

_release_filesystem() {
  local repo_root="$1" helper cache_root operation
  shift
  operation="$1"
  shift
  helper="$(_release_filesystem_script "$repo_root")" || return 69
  cache_root="${TMPDIR:-/tmp}/lidmute-release-filesystem-cache"
  if [[ "${LIDMUTE_DIST_HANDLE_ACTIVE:-0}" == "1" ]]; then
    [[ "${LIDMUTE_DIST_FD:-}" == <-> ]] || return 69
    [[ "${LIDMUTE_DIST_ROOT:-}" == "." ]] || return 69
    CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}" \
      SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$cache_root/swift}" \
      swift "$helper" verify-handle "$LIDMUTE_DIST_FD" "$repo_root" || return $?
    CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}" \
      SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$cache_root/swift}" \
      swift "$helper" "$operation" "$LIDMUTE_DIST_FD" "$@"
    return $?
  fi

  # Enter the repository's dist directory once, hold it by descriptor, and
  # run the requested helper operation through that descriptor.
  CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}" \
    SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$cache_root/swift}" \
    swift "$helper" with-dist "$repo_root" /bin/zsh -c '
      set -euo pipefail
      helper="$1"
      shift
      operation="$1"
      shift
      swift "$helper" "$operation" "$LIDMUTE_DIST_FD" "$@"
    ' zsh "$helper" "$operation" "$@"
}

_validate_managed_dist_child() {
  local repo_root="$1" candidate="$2" kind="$3"
  local canonical_root dist canonical_dist parent canonical_parent base
  canonical_root="$(cd -P -- "$repo_root" && pwd)" || return 64
  dist="$canonical_root/dist"
  canonical_dist="$(cd -P -- "$dist" 2>/dev/null && pwd)" || return 64
  [[ "$canonical_dist" == "$dist" ]] || return 64
  parent="${candidate:h}"
  base="${candidate:t}"
  canonical_parent="$(cd -P -- "$parent" 2>/dev/null && pwd)" || return 64
  [[ "$canonical_parent" == "$canonical_dist" ]] || return 64
  case "$kind" in
    stage) [[ "$base" == .lidmute-stage.* && "$base" != ".lidmute-stage." ]] || return 64 ;;
    backup) [[ "$base" == .lidmute-backup.* && "$base" != ".lidmute-backup." ]] || return 64 ;;
    *) return 64 ;;
  esac
  [[ ! -L "$candidate" ]] || return 64
  print -r -- "$canonical_parent/$base"
}

_active_dist_child() {
  local candidate="$1" kind="$2" dist_root="${LIDMUTE_DIST_ROOT:-.}" base
  [[ "${LIDMUTE_DIST_HANDLE_ACTIVE:-0}" == "1" ]] || return 64
  base="${candidate:t}"
  [[ "${candidate:h}" == "$dist_root" ]] || return 64
  case "$kind" in
    stage) [[ "$base" == .lidmute-stage.* && "$base" != ".lidmute-stage." ]] || return 64 ;;
    backup) [[ "$base" == .lidmute-backup.* && "$base" != ".lidmute-backup." ]] || return 64 ;;
    *) return 64 ;;
  esac
  print -r -- "$base"
}

cleanup_output_bundle() {
  local repo_root="$1" candidate="$2" safe base
  safe="$(validate_output_path "$repo_root" "$candidate")" || return 64
  [[ ! -L "$safe" ]] || return 64
  base="${safe:t}"
  _release_filesystem "$repo_root" remove app "$base"
}

cleanup_staging() {
  local repo_root="$1" staging="$2" base
  if [[ "${LIDMUTE_DIST_HANDLE_ACTIVE:-0}" == "1" ]]; then
    base="$(_active_dist_child "$staging" stage)" || return 64
  else
    [[ -e "$staging" ]] || return 0
    base="$(_validate_managed_dist_child "$repo_root" "$staging" stage)" || return 64
    base="${base:t}"
  fi
  _release_filesystem "$repo_root" remove stage "$base"
}

_cleanup_backup() {
  local repo_root="$1" backup="$2" base
  if [[ "${LIDMUTE_DIST_HANDLE_ACTIVE:-0}" == "1" ]]; then
    base="$(_active_dist_child "$backup" backup)" || return 64
  else
    [[ -e "$backup" ]] || return 0
    base="$(_validate_managed_dist_child "$repo_root" "$backup" backup)" || return 64
    base="${base:t}"
  fi
  _release_filesystem "$repo_root" remove backup "$base"
}

_validate_staged_app() {
  local repo_root="$1" staged_app="$2" destination="$3"
  local staging safe_staging destination_safe dist_root destination_name
  staging="${staged_app:h}"
  if [[ "${LIDMUTE_DIST_HANDLE_ACTIVE:-0}" == "1" ]]; then
    dist_root="${LIDMUTE_DIST_ROOT:-.}"
    [[ "$staging" == "$dist_root"/.lidmute-stage.* ]] || return 64
    destination_name="${destination:t}"
    [[ "${destination:h}" == "$dist_root" ]] || return 64
    [[ "$destination_name" == *.app && "$destination_name" != ".app" ]] || return 64
    [[ "${staged_app:t}" == "$destination_name" ]] || return 64
    [[ -d "$staged_app" && ! -L "$staged_app" ]] || return 64
    print -r -- "$staged_app"
    return 0
  fi
  destination_safe="$(validate_output_path "$repo_root" "$destination")" || return 64
  safe_staging="$(_validate_managed_dist_child "$repo_root" "$staging" stage)" || return 64
  [[ "$staging" == "$safe_staging" ]] || return 64
  [[ "${staged_app:t}" == "${destination_safe:t}" ]] || return 64
  [[ -d "$staged_app" && ! -L "$staged_app" ]] || return 64
  print -r -- "$staged_app"
}

install_staged_bundle() {
  local repo_root="$1" staged_app="$2" destination="$3"
  local safe_staged safe_destination stage_name app_name destination_name dist_root
  if [[ "${LIDMUTE_DIST_HANDLE_ACTIVE:-0}" == "1" ]]; then
    safe_destination="$destination"
  else
    safe_destination="$(validate_output_path "$repo_root" "$destination")" || return 64
  fi
  safe_staged="$(_validate_staged_app "$repo_root" "$staged_app" "$safe_destination")" || return 64
  stage_name="${safe_staged:h:t}"
  app_name="${safe_staged:t}"
  destination_name="${safe_destination:t}"
  [[ "$app_name" == "$destination_name" ]] || return 64
  if [[ "${LIDMUTE_DIST_HANDLE_ACTIVE:-0}" == "1" ]]; then
    dist_root="${LIDMUTE_DIST_ROOT:-.}"
    [[ "${safe_staged:h:h}" == "$dist_root" ]] || return 64
  fi
  _release_filesystem "$repo_root" install "$stage_name" "$app_name" "$destination_name"
}

sign_adhoc_bundle() {
  local repo_root="$1" app="$2" entitlements="$1/Config/LidMuteRelease.entitlements"
  codesign --force --sign - "$app/Contents/MacOS/LidMuteNativeHost"
  codesign --force --sign - --entitlements "$entitlements" "$app/Contents/MacOS/LidMute"
  codesign --force --sign - --entitlements "$entitlements" "$app"
}

sign_developer_id_bundle() {
  local repo_root="$1" app="$2" identity="$3" entitlements="$1/Config/LidMuteRelease.entitlements"
  codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/MacOS/LidMuteNativeHost"
  codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app/Contents/MacOS/LidMute"
  codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$identity" "$app"
}

_verify_bundle_identifier() {
  local app="$1" details
  details="$(codesign -d --verbose=4 "$app" 2>&1)" || return 70
  print -r -- "$details" | grep -Fqx 'Identifier=local.lidmute.app' || return 70
}

_verify_release_entitlements() {
  local app="$1" entitlements
  entitlements="$(codesign -d --entitlements :- "$app" 2>&1)" || return 70
  [[ "$entitlements" != *get-task-allow* ]] || return 70
}

_verify_nested_signatures() {
  local app="$1"
  codesign --verify --strict --verbose=2 "$app/Contents/MacOS/LidMuteNativeHost"
  codesign --verify --strict --verbose=2 "$app/Contents/MacOS/LidMute"
  codesign --verify --strict --verbose=2 "$app"
}

verify_adhoc_bundle() {
  local app="$1"
  _verify_nested_signatures "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  _verify_release_entitlements "$app"
  _verify_bundle_identifier "$app"
}

verify_developer_id_bundle() {
  local app="$1" details authority team
  _verify_nested_signatures "$app"
  _verify_release_entitlements "$app"
  _verify_bundle_identifier "$app"
  details="$(codesign -d --verbose=4 "$app" 2>&1)" || return 70
  print -r -- "$details" | grep -Eq '^CodeDirectory .* flags=.*\(runtime\)' || return 70
  authority="$(print -r -- "$details" | sed -n 's/^Authority=//p' | head -n 1)"
  team="$(print -r -- "$details" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  [[ -n "$authority" && -n "$team" && "$team" != "not set" ]] || return 70
  spctl --assess --type execute --verbose=4 "$app"
}

notarize_and_staple() {
  local app="$1" profile="$2" staging="$3" archive
  [[ -n "$profile" ]] || return 64
  [[ -d "$staging" && ! -L "$staging" && "${staging:t}" == .lidmute-stage.* ]] || return 64
  [[ "${app:h}" == "$staging" && -d "$app" && ! -L "$app" ]] || return 64
  archive="$staging/LidMute-notarization.zip"
  ditto -c -k --keepParent "$app" "$archive"
  xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
}
