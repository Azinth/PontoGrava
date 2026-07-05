#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
OUTPUT="$ROOT/outputs"
APP="$OUTPUT/PontoGrava.app"
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

cd "$ROOT"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/PontoGrava" "$APP/Contents/MacOS/PontoGrava"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/PontoGrava"

ICONSET="$ROOT/work/PontoGrava.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for SPEC in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'; do
  SIZE="${SPEC%% *}"
  NAME="${SPEC#* }"
  sips -z "$SIZE" "$SIZE" "$ROOT/Resources/PontoGravaIcon.png" --out "$ICONSET/$NAME" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/PontoGrava.icns"
cp "$ROOT/Resources/PontoGravaIcon.png" "$OUTPUT/PontoGrava-icon.png"

codesign --force --deep --sign - "$APP"
echo "$APP"
