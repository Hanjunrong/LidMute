#!/bin/zsh

validate_output_path() {
  local repo_root="$1" candidate="$2"
  local canonical_root dist canonical_dist parent base canonical_parent resolved
  canonical_root="$(cd -P -- "$repo_root" && pwd)" || return 64
  dist="$canonical_root/dist"
  mkdir -p -- "$dist" || return 64
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

cleanup_output_bundle() {
  local repo_root="$1" candidate="$2" safe
  safe="$(validate_output_path "$repo_root" "$candidate")" || return 64
  [[ ! -L "$safe" ]] || return 64
  if [[ -e "$safe" ]]; then
    rm -rf -- "$safe"
  fi
}

cleanup_staging() {
  local repo_root="$1" staging="$2" safe_staging
  [[ -e "$staging" ]] || return 0
  safe_staging="$(_validate_managed_dist_child "$repo_root" "$staging" stage)" || return 64
  rm -rf -- "$safe_staging"
}

_cleanup_backup() {
  local repo_root="$1" backup="$2" safe_backup
  safe_backup="$(_validate_managed_dist_child "$repo_root" "$backup" backup)" || return 64
  [[ -e "$safe_backup" ]] || return 0
  rm -rf -- "$safe_backup"
}

_validate_staged_app() {
  local repo_root="$1" staged_app="$2" destination="$3"
  local staging safe_staging destination_safe
  staging="${staged_app:h}"
  safe_staging="$(_validate_managed_dist_child "$repo_root" "$staging" stage)" || return 64
  destination_safe="$(validate_output_path "$repo_root" "$destination")" || return 64
  [[ "$staging" == "$safe_staging" ]] || return 64
  [[ "${staged_app:t}" == "${destination_safe:t}" ]] || return 64
  [[ -d "$staged_app" && ! -L "$staged_app" ]] || return 64
  print -r -- "$staged_app"
}

install_staged_bundle() {
  local repo_root="$1" staged_app="$2" destination="$3"
  local safe_staged safe_destination canonical_root dist backup=""
  safe_destination="$(validate_output_path "$repo_root" "$destination")" || return 64
  safe_staged="$(_validate_staged_app "$repo_root" "$staged_app" "$safe_destination")" || return 64
  canonical_root="$(cd -P -- "$repo_root" && pwd)" || return 64
  dist="$canonical_root/dist"

  if [[ -e "$safe_destination" ]]; then
    [[ ! -L "$safe_destination" ]] || return 64
    backup="$dist/.lidmute-backup.$(uuidgen)"
    _validate_managed_dist_child "$repo_root" "$backup" backup >/dev/null || return 64
    mv -- "$safe_destination" "$backup" || return 74
  fi

  if ! mv -- "$safe_staged" "$safe_destination"; then
    if [[ -n "$backup" && -e "$backup" ]]; then
      mv -- "$backup" "$safe_destination" || {
        print -u2 "Failed to install staged App and restore the previous App"
        return 74
      }
    fi
    return 74
  fi

  if [[ -n "$backup" ]]; then
    _cleanup_backup "$repo_root" "$backup" || return 74
  fi
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
