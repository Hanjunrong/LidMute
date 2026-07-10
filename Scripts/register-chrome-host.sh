#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
  print "Usage: $0 /absolute/path/to/LidMuteNativeHost chrome-extension-id" >&2
  exit 64
fi

host_path="$1"
extension_id="$2"
origin="chrome-extension://${extension_id}/"
app_support="$HOME/Library/Application Support/LidMute"
manifest_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
manifest_path="$manifest_dir/com.lidmute.nativehost.json"

[[ "$host_path" = /* && -x "$host_path" ]] || { print "Native host must be an executable absolute path." >&2; exit 66; }
mkdir -p "$app_support" "$manifest_dir"
chmod 700 "$app_support"
print -r -- "$origin" > "$app_support/chrome-origin.txt"
chmod 600 "$app_support/chrome-origin.txt"

cat > "$manifest_path" <<EOF
{"name":"com.lidmute.nativehost","description":"LidMute Chrome bridge","path":"$host_path","type":"stdio","allowed_origins":["$origin"]}
EOF
chmod 600 "$manifest_path"
print "Registered LidMute for $origin"
