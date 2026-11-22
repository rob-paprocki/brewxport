#!/bin/bash
# Renders Resources/icon/AppIcon.svg into Resources/bundle/AppIcon.icns (every macOS icon size, 16 to 1024).
# Run it after changing the SVG, then approve the new .icns in Tests/approved-binaries.txt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Resources/icon/AppIcon.svg"
OUT="$ROOT/Resources/bundle/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
    swift "$ROOT/scripts/render-svg.swift" "$SVG" "$SET/icon_${size}x${size}.png" "$size"
    swift "$ROOT/scripts/render-svg.swift" "$SVG" "$SET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$SET" -o "$OUT"
echo "made $OUT"
