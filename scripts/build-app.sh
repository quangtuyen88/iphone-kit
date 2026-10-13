#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
swift build --package-path "$ROOT" -c "$CONFIGURATION"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP="${IPHONEKIT_APP_PATH:-$ROOT/dist/IPhoneKit.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN/IPhoneKit" "$APP/Contents/MacOS/IPhoneKit"
cp "$BIN/iphonekit-mcp" "$APP/Contents/MacOS/iphonekit-mcp"
if [[ -f "$ROOT/App/AppIcon.icns" ]]; then cp "$ROOT/App/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application|Apple Development/ {print $2; exit}')"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/MacOS/iphonekit-mcp"
codesign --force --sign "$IDENTITY" --options runtime --entitlements "$ROOT/App/Entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
