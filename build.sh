#!/bin/bash
# Builds FolderPilot.app (and the fpilot CLI) into ./build
set -euo pipefail
cd "$(dirname "$0")"

# SwiftUI macros need the full Xcode toolchain, not just Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# UNIVERSAL=1 builds one app for both Apple Silicon and Intel Macs.
ARCHS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR=$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)

ICON=Resources/AppIcon.icns
if [ ! -f "$ICON" ]; then
  TMP=$(mktemp -d)
  swift Scripts/make-icon.swift "$TMP/icon.png"
  SET="$TMP/AppIcon.iconset"; mkdir "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON"
  rm -rf "$TMP"
fi

APP=build/FolderPilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FolderPilot" "$APP/Contents/MacOS/FolderPilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/fpilot" build/fpilot
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $(pwd)/$APP"
echo "CLI:  $(pwd)/build/fpilot"
echo "To install: cp -R \"$APP\" /Applications/"
