#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/FlowRecorder.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
CLASSROOM_ROOT="$ROOT/Classroom"
CLASSROOM_RESOURCES="$RESOURCES/Classroom"

rm -rf "$APP"
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"
mkdir -p "$CLASSROOM_RESOURCES"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppIcon.icns" "$RESOURCES/AppIcon.icns"

npm run build --prefix "$CLASSROOM_ROOT" >/dev/null
"$CLASSROOM_ROOT/node_modules/.bin/esbuild" \
  "$CLASSROOM_ROOT/apps/server/src/index.ts" \
  --bundle \
  --platform=node \
  --format=esm \
  --target=node24 \
  --outfile="$CLASSROOM_RESOURCES/server.mjs" \
  --banner:js='import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' \
  >/dev/null
cp -R "$CLASSROOM_ROOT/apps/web/dist" "$CLASSROOM_RESOURCES/web"
NODE_BINARY="$(realpath "$(command -v node)")"
cp "$NODE_BINARY" "$CLASSROOM_RESOURCES/node"
chmod 755 "$CLASSROOM_RESOURCES/node"

NODE_LICENSE="$(dirname "$(dirname "$NODE_BINARY")")/LICENSE"
if [[ -f "$NODE_LICENSE" ]]; then
  cp "$NODE_LICENSE" "$CLASSROOM_RESOURCES/Node-LICENSE.txt"
fi

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
  codesign --force --sign "$LOCAL_IDENTITY" "$CLASSROOM_RESOURCES/node" >/dev/null
  codesign --force --deep --sign "$LOCAL_IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - "$CLASSROOM_RESOURCES/node" >/dev/null
  codesign --force --deep --sign - "$APP" >/dev/null
fi

echo "$APP"
