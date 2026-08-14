#!/usr/bin/env bash
# Build a styled drag-to-Install DMG from an .app bundle.
#
#   tool/make_dmg.sh <Octodo.app> <out.dmg> <background.png>
#
# Recipe (empirically required on current macOS):
#   - mount the UDRW image at /Volumes/Octodo (a custom mountpoint
#     silently prevents Finder from writing .DS_Store)
#   - compute the background alias OUTSIDE the Finder tell block
#     (POSIX file is a StandardAdditions term; inside the tell it
#     fails with -1700)
#   - Finder persists the layout (bounds, 128pt icons, positions,
#     background) to .DS_Store on window close
# Then convert to compressed UDZO. Shared by local builds and release.yml.
set -euo pipefail

APP="$1"
OUT="$2"
BG="$3"
VOL="Octodo"
MNT="/Volumes/$VOL"

[[ -d "$APP" ]] || { echo "error: app not found: $APP" >&2; exit 1; }
[[ -f "$BG" ]] || { echo "error: background not found: $BG" >&2; exit 1; }
if mount | grep -q " $MNT "; then
  echo "error: $MNT is mounted (unmount it first)" >&2
  exit 1
fi
mkdir -p "$MNT" 2>/dev/null || true

STAGE=$(mktemp -d)
RW=$(mktemp -u).dmg
cleanup() {
  hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true
  rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

cp -R "$APP" "$STAGE/Octodo.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.png"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW "$RW" -quiet
hdiutil attach "$RW" -mountpoint "$MNT" -noverify -nobrowse -noautoopen -quiet

# Finder needs a moment on cold launches; retry a few times (first
# attempt often fails with -1728 while the disk registers). The script
# lives in a file because osascript reads stdin once.
APPLESCRIPT=$(mktemp)
cat >"$APPLESCRIPT" <<AS
on run
  set bg to POSIX file "$MNT/.background/background.png" as alias
  tell application "Finder"
    tell disk "$VOL"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 860, 608}
      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to 128
      set background picture of theViewOptions to bg
      set position of item "$VOL" of container window to {101, 166}
      set position of item "Applications" of container window to {431, 166}
      update without registering applications
      delay 2
      close
    end tell
  end tell
end run
AS

ok=0
for i in 1 2 3 4 5; do
  if osascript "$APPLESCRIPT"; then ok=1; break; fi
  sleep 2
done
[[ $ok == 1 ]] || { echo "error: Finder layout script failed" >&2; exit 1; }

# The layout lands in .DS_Store — fail loudly if Finder never wrote it.
ok=0
for i in 1 2 3 4 5; do
  if [[ -f "$MNT/.DS_Store" ]]; then ok=1; break; fi
  sleep 2
done
[[ $ok == 1 ]] || { echo "error: .DS_Store not written by Finder" >&2; exit 1; }

# Gentle detach first so Finder can flush; force after retries.
for i in 1 2 3; do
  hdiutil detach "$MNT" -quiet && break
  sleep 2
  [[ $i == 3 ]] && hdiutil detach "$MNT" -force -quiet
done

hdiutil convert "$RW" -format UDZO -ov -o "$OUT" -quiet
echo "created: $OUT"
