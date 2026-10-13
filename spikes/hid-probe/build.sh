#!/usr/bin/env bash
# Builds HIDProbe.app (ad-hoc signed) so macOS attributes Bluetooth/Camera TCC to it.
# Run:  spikes/hid-probe/build.sh && open spikes/hid-probe/build/HIDProbe.app --args auto|pair|desc
# Log:  /tmp/iphonekit-probe.log
set -euo pipefail
cd "$(dirname "$0")"
APP=build/HIDProbe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/HIDProbe" Probe.swift \
  -framework AppKit -framework IOBluetooth -framework CoreBluetooth \
  -framework AVFoundation -framework CoreMediaIO
# A stable signing identity keeps the Bluetooth/Camera grants across rebuilds (ad-hoc re-prompts every build).
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP" >/dev/null
echo "$PWD/$APP"
