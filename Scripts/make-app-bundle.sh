#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
source "$root/Scripts/lib/release-packaging.zsh"

app="$(validate_output_path "$root" "${LIDMUTE_APP_PATH:-$root/dist/LidMute.app}")"
mode="$(resolve_signing_mode "${LIDMUTE_SIGNING_MODE:-}")"
if [[ "$mode" == "developer-id" ]]; then
  validate_developer_id_inputs "${LIDMUTE_DEVELOPER_IDENTITY:-}" "${LIDMUTE_NOTARY_PROFILE:-}"
fi

temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$temp_root/lidmute-clang-cache}"
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-$temp_root/lidmute-swiftpm-cache}"
scratch="${LIDMUTE_SCRATCH_PATH:-$temp_root/lidmute-build}"
dist="$root/dist"
mkdir -p -- "$dist"
staging="$(mktemp -d "$dist/.lidmute-stage.XXXXXX")"
trap 'cleanup_staging "$root" "$staging"' EXIT ZERR INT TERM
staged_app="$staging/${app:t}"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"

build_args=(
  --package-path "$root"
  --disable-sandbox
  --scratch-path "$scratch"
  --configuration release
)
if [[ -n "${LIDMUTE_BUILD_TRIPLE:-}" ]]; then
  build_args+=(--triple "$LIDMUTE_BUILD_TRIPLE")
fi

# Packaging is only allowed from a build completed by this invocation.
# No environment variable may bypass this build or point at another bin path.
print "LidMute packaging configuration: release"
print "LidMute signing mode: $mode"
if [[ "$mode" == "adhoc" ]]; then
  print "本地验收包，不可公开分发"
fi
"$root/Scripts/check-visual-principles.sh"
swift build "${build_args[@]}"
build_root="$(swift build "${build_args[@]}" --show-bin-path)"

case "/$build_root/" in
  */release/*) ;;
  *)
    print -u2 "Refusing non-Release build provenance: $build_root"
    exit 67
    ;;
esac

binary="$build_root/LidMuteApp"
host="$build_root/LidMuteNativeHost"
icon_source="$root/Assets/AppIcon-1024.png"

[[ -x "$binary" && -x "$host" ]] || {
  print "Build did not produce both LidMuteApp and LidMuteNativeHost in $build_root" >&2
  exit 66
}

stale_source="$(find "$root/Sources" -type f -newer "$binary" -print -quit)"
[[ -z "$stale_source" ]] || {
  print "Refusing to package stale binary: $binary is older than $stale_source" >&2
  exit 67
}

stale_source="$(find "$root/Sources" -type f -newer "$host" -print -quit)"
[[ -z "$stale_source" ]] || {
  print "Refusing to package stale binary: $host is older than $stale_source" >&2
  exit 67
}

cp "$binary" "$staged_app/Contents/MacOS/LidMute"
cp "$host" "$staged_app/Contents/MacOS/LidMuteNativeHost"
mkdir -p "$staged_app/Contents/Resources/ChromeExtension"
ditto "$root/ChromeExtension" "$staged_app/Contents/Resources/ChromeExtension"
cp "$root/Scripts/register-chrome-host.sh" "$staged_app/Contents/Resources/register-chrome-host.sh"

iconset="$staging/LidMute.iconset"
mkdir -p "$iconset"
for spec in \
  "16 icon_16x16.png" "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$icon_source" --out "$iconset/$name" >/dev/null
done
swift "$root/Scripts/build-icon.swift" "$iconset" "$staged_app/Contents/Resources/AppIcon.icns"

short_version="$(read_version_value "$root/Config/Version.plist" CFBundleShortVersionString)"
build_version="$(read_version_value "$root/Config/Version.plist" CFBundleVersion)"

cat > "$staged_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>LidMute</string>
  <key>CFBundleExecutable</key><string>LidMute</string>
  <key>CFBundleIdentifier</key><string>local.lidmute.app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>LidMute</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$short_version</string>
  <key>CFBundleVersion</key><string>$build_version</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
EOF

case "$mode" in
  adhoc)
    print 'local-adhoc' > "$staged_app/Contents/Resources/BuildChannel.txt"
    sign_adhoc_bundle "$root" "$staged_app"
    verify_adhoc_bundle "$staged_app"
    ;;
  developer-id)
    print 'developer-id-notarized' > "$staged_app/Contents/Resources/BuildChannel.txt"
    sign_developer_id_bundle "$root" "$staged_app" "$LIDMUTE_DEVELOPER_IDENTITY"
    notarize_and_staple "$staged_app" "$LIDMUTE_NOTARY_PROFILE" "$staging"
    verify_developer_id_bundle "$staged_app"
    ;;
esac

install_staged_bundle "$root" "$staged_app" "$app"

print "Created $app"
