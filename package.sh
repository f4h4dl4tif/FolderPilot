#!/bin/bash
# Builds a universal FolderPilot.app and wraps it in an installer package: dist/FolderPilot-<version>.pkg
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
PKG_ID=app.folderpilot.FolderPilot.pkg
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/root/Applications" "$WORK/scripts" dist
cp -R build/FolderPilot.app "$WORK/root/Applications/"
# Drop removable extended attributes (quarantine, Finder info). macOS-managed com.apple.provenance
# cannot be removed; it appears as ._ entries in the payload and does not affect code signing.
xattr -cr "$WORK/root" 2>/dev/null || true
export COPYFILE_DISABLE=1

# Always install into /Applications, even if another copy of FolderPilot exists elsewhere on the Mac.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/components.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"

# Quit a running copy before upgrading so the new version starts cleanly.
cat > "$WORK/scripts/preinstall" <<'SH'
#!/bin/bash
pkill -x FolderPilot 2>/dev/null || true
exit 0
SH
chmod +x "$WORK/scripts/preinstall"

pkgbuild --root "$WORK/root" \
  --component-plist "$WORK/components.plist" \
  --scripts "$WORK/scripts" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location / \
  "$WORK/FolderPilot-component.pkg" >/dev/null

cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>FolderPilot</title>
    <welcome file="welcome.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="14.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"><line choice="app"/></line></choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false"><pkg-ref id="$PKG_ID"/></choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">FolderPilot-component.pkg</pkg-ref>
</installer-gui-script>
XML

OUT="dist/FolderPilot-$VERSION.pkg"
productbuild --distribution "$WORK/distribution.xml" \
  --resources Installer/resources \
  --package-path "$WORK" \
  "$OUT" >/dev/null

echo "Created $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"
