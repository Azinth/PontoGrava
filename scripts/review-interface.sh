#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build
REVIEW_APP="$ROOT/outputs/InterfaceReview.app"
mkdir -p "$REVIEW_APP/Contents/MacOS"
cp "$(swift build --show-bin-path)/PontoGrava" "$REVIEW_APP/Contents/MacOS/PontoGrava"
cp "$ROOT/Resources/Info.plist" "$REVIEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.pontograva.interface-review' "$REVIEW_APP/Contents/Info.plist"
codesign --force --deep --sign - "$REVIEW_APP"
"$REVIEW_APP/Contents/MacOS/PontoGrava" --review-interface "$ROOT/outputs/interface-review"
