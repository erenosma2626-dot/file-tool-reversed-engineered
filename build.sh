#!/bin/bash
# Builds Facet.app into ./dist using only the Xcode Command Line Tools.
#   ./build.sh            release build
#   ./build.sh --install  also copies the app into /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=dist/Facet.app
echo "› Compiling (release)…"
swift build -c release --arch arm64

BIN="$(swift build -c release --arch arm64 --show-bin-path)/Facet"

echo "› Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/Facet"
strip -x "$APP/Contents/MacOS/Facet" 2>/dev/null || true
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: prefer a prebuilt .icns, otherwise generate one from the 1024px PNG.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [ -f Resources/AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cp Resources/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"

# Optional media engine (MKV / WebM / MP3). Run Scripts/fetch-ffmpeg.sh once to get it.
if [ -x Vendor/ffmpeg ]; then
  cp Vendor/ffmpeg "$APP/Contents/Helpers/ffmpeg"
  echo "› Bundled ffmpeg"
fi

echo "› Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

du -sh "$APP" | awk '{print "› Done: '"$APP"' (" $1 ")"}'

if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Facet.app
  cp -R "$APP" /Applications/
  echo "› Installed to /Applications/Facet.app"
fi
