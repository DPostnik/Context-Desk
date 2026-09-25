#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source_icon="$PWD/Assets/AppIcon/source-v1.png"
iconset="$PWD/build/ContextDesk.iconset"
mkdir -p "$iconset"
# Format conversion only: preserve the generated artwork and its alpha channel.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$PWD/Assets/AppIcon/AppIcon.icns"
