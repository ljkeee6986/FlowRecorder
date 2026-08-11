#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/FlowRecorder.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$RESOURCES/AppIcon.icns"

swiftc \
  -parse-as-library \
  -target arm64-apple-macosx15.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework SwiftUI \
  "$ROOT/Sources/FlowRecorderApp.swift" \
  -o "$MACOS/录屏大师Jack"

LOCAL_IDENTITY="83375B700E027795A327CC41FE0EFCC1805A4810"

if security find-identity -v -p codesigning | grep -q "$LOCAL_IDENTITY"; then
  codesign --force --deep --sign "$LOCAL_IDENTITY" "$APP" >/dev/null
else
  codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "$APP"
