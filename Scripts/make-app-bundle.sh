#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$temp_root/lidmute-clang-cache}"
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-$temp_root/lidmute-swiftpm-cache}"
scratch="${LIDMUTE_SCRATCH_PATH:-$temp_root/lidmute-build}"
app="${LIDMUTE_APP_PATH:-$root/dist/LidMute.app}"

build_args=(
  --package-path "$root"
  --disable-sandbox
  --scratch-path "$scratch"
)
if [[ -n "${LIDMUTE_BUILD_TRIPLE:-}" ]]; then
  build_args+=(--triple "$LIDMUTE_BUILD_TRIPLE")
fi

# Packaging is only allowed from a build completed by this invocation.
# No environment variable may bypass this build or point at another bin path.
"$root/Scripts/check-visual-principles.sh"
swift build "${build_args[@]}"
build_root="$(swift build "${build_args[@]}" --show-bin-path)"

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

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/LidMute"
cp "$host" "$app/Contents/MacOS/LidMuteNativeHost"
mkdir -p "$app/Contents/Resources/ChromeExtension"
ditto "$root/ChromeExtension" "$app/Contents/Resources/ChromeExtension"
cp "$root/Scripts/register-chrome-host.sh" "$app/Contents/Resources/register-chrome-host.sh"

iconset="$scratch/LidMute.iconset"
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
swift "$root/Scripts/build-icon.swift" "$iconset" "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'EOF'
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
EOF

print "Created $app"
