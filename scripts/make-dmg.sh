#!/bin/bash
# Build an installer DMG: app + Applications drop target + Read Me + optional
# background with Finder icon layout.
#   scripts/make-dmg.sh <app-path> <volume-name> <output.dmg> [background.png]
set -euo pipefail
APP=$1; VOL=$2; OUT=$3; BG=${4:-}
APPNAME=$(basename "$APP")
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me.txt" <<TXT
Keepsake Atelier install
===================

1. Drag "$APPNAME" onto the Applications folder in this window.
2. Eject this disk image.
3. Open the app from Applications.

The build is not notarized. On first launch macOS will refuse it:
- Right click the app, choose Open, then Open again, or
- run: xattr -dr com.apple.quarantine "/Applications/$APPNAME"

The app bundles ffmpeg and ffprobe, so no extra tools are needed.
TXT

if [ -n "$BG" ] && [ -f "$BG" ]; then
  mkdir -p "$STAGE/.background"
  cp "$BG" "$STAGE/.background/background.png"
fi

TMP=$(mktemp -u).dmg
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$TMP" >/dev/null
# The mount point contains spaces ("/Volumes/Keepsake Atelier"), so take
# everything after the device and type columns, not just field 3.
# The first output line is the whole disk and has no mount point; take the
# first line that has one, and keep the spaces in "/Volumes/<name>".
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP" \
  | awk '$1 ~ /^\/dev\/disk/ && NF >= 3 { sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, ""); print; exit }')
if [ -n "$BG" ] && [ -f "$BG" ]; then
  APPNAME="$APPNAME" VOLUME_NAME="$VOL" osascript <<'OSA' 2>/dev/null || true
set appName to system attribute "APPNAME"
set volName to system attribute "VOLUME_NAME"
tell application "Finder"
  tell disk volName
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 200, 820, 580}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set background picture of viewOptions to file ".background:background.png"
    set position of item appName of container window to {150, 215}
    set position of item "Applications" of container window to {470, 215}
    set position of item "Read Me.txt" of container window to {310, 355}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
OSA
fi
sync
# A Finder-held mount refuses a polite detach; force it, or the next build
# stacks another "/Volumes/<name> N" and hdiutil convert runs out of room.
hdiutil detach "$MNT" >/dev/null 2>&1 \
  || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
hdiutil convert "$TMP" -format UDZO -o "$OUT" >/dev/null
rm -rf "$STAGE" "$TMP"
echo "built $OUT (app + Applications link + Read Me + background)"
