#!/bin/bash
# Builds a universal FolderPilot.app and packs it into a drag-to-install disk image: dist/FolderPilot-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh
ARCHS=$(lipo -archs build/FolderPilot.app/Contents/MacOS/FolderPilot)
case "$ARCHS" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "Expected a universal binary, got: $ARCHS"; exit 1;; esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/FolderPilot.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Installer/How to Install.txt" "$STAGE/"
mkdir "$STAGE/Example Workflows"
cp Examples/*.folderpilot "$STAGE/Example Workflows/"

mkdir -p dist
OUT="dist/FolderPilot-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "FolderPilot" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
echo "Created $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"
