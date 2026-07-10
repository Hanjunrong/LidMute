#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
scratch="${LIDMUTE_SCRATCH_PATH:-$temp_root/lidmute-build}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$temp_root/lidmute-clang-cache}"
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-$temp_root/lidmute-swiftpm-cache}"
build_root="${LIDMUTE_BUILD_ROOT:-$(swift build --package-path "$root" --disable-sandbox --scratch-path "$scratch" --show-bin-path)}"
app="${LIDMUTE_APP_PATH:-$root/dist/LidMute.app}"
binary="$build_root/LidMuteApp"
host="$build_root/LidMuteNativeHost"
icon_source="$root/Assets/AppIcon-1024.png"

[[ -x "$binary" && -x "$host" ]] || {
  print "Build first: zsh Scripts/run-smoke-check.sh" >&2
  exit 66
}

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/LidMute"
cp "$host" "$app/Contents/MacOS/LidMuteNativeHost"
mkdir -p "$app/Contents/Resources/ChromeExtension"
ditto "$root/ChromeExtension" "$app/Contents/Resources/ChromeExtension"

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
