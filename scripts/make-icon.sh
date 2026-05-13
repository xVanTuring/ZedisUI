#!/usr/bin/env bash
#
# Rasterize Resources/AppIcon.svg into the macOS AppIcon.appiconset.
#
# Run after any edit to AppIcon.svg. The output PNGs and Contents.json
# are committed to the repo so the release pipeline doesn't need
# rsvg-convert; only this script does.
#
# Requires: rsvg-convert (brew install librsvg)
#
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="Resources/AppIcon.svg"
ASSETS="Resources/Assets.xcassets"
DEST="$ASSETS/AppIcon.appiconset"

[[ -f "$SRC" ]] || { echo "ERROR: $SRC not found" >&2; exit 1; }
command -v rsvg-convert >/dev/null \
    || { echo "ERROR: rsvg-convert not on PATH. Install: brew install librsvg" >&2; exit 1; }

mkdir -p "$DEST"

# Apple's mac idiom AppIcon: 5 base sizes × @1x + @2x = 10 PNGs.
# Format: "<base-pt>:<scale>:<filename>"
sizes=(
    "16:1:icon_16x16.png"
    "16:2:icon_16x16@2x.png"
    "32:1:icon_32x32.png"
    "32:2:icon_32x32@2x.png"
    "128:1:icon_128x128.png"
    "128:2:icon_128x128@2x.png"
    "256:1:icon_256x256.png"
    "256:2:icon_256x256@2x.png"
    "512:1:icon_512x512.png"
    "512:2:icon_512x512@2x.png"
)

echo "==> Rasterizing $SRC"
for entry in "${sizes[@]}"; do
    IFS=":" read -r base scale name <<< "$entry"
    px=$((base * scale))
    printf "  %s  (%d×%d)\n" "$name" "$px" "$px"
    rsvg-convert -w "$px" -h "$px" "$SRC" -o "$DEST/$name"
done

cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16",   "scale" : "1x", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "size" : "16x16",   "scale" : "2x", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "1x", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "size" : "32x32",   "scale" : "2x", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
JSON

# Asset catalog root needs its own Contents.json so Xcode recognises
# the bundle.
if [[ ! -f "$ASSETS/Contents.json" ]]; then
    cat > "$ASSETS/Contents.json" <<'JSON'
{ "info" : { "version" : 1, "author" : "xcode" } }
JSON
fi

echo "==> Wrote $DEST + Contents.json"
