#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
build_root="${TMPDIR%/}/lidmute-build/arm64-apple-macosx/debug"
app="$root/dist/LidMute.app"
binary="$build_root/LidMuteApp"
host="$build_root/LidMuteNativeHost"

[[ -x "$binary" && -x "$host" ]] || {
  print "Build first: zsh Scripts/run-smoke-check.sh" >&2
  exit 66
}

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/LidMute"
cp "$host" "$app/Contents/MacOS/LidMuteNativeHost"
cp -R "$root/ChromeExtension" "$app/Contents/Resources/ChromeExtension"

cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>LidMute</string>
  <key>CFBundleExecutable</key><string>LidMute</string>
  <key>CFBundleIdentifier</key><string>local.lidmute.app</string>
  <key>CFBundleName</key><string>LidMute</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
EOF

print "Created $app"
