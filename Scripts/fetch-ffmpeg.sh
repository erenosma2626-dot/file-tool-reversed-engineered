#!/bin/bash
# Puts a self-contained arm64 ffmpeg into Vendor/ffmpeg so build.sh can bundle it.
# ffmpeg is only needed for MKV, WebM and MP3. Everything else uses macOS frameworks.
#
# Order of preference:
#   1. FFMPEG=/path/to/ffmpeg ./Scripts/fetch-ffmpeg.sh   (any static binary you already have)
#   2. Download a static build from osxexperts.net
# A Homebrew ffmpeg also works without bundling: Facet looks in /opt/homebrew/bin automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Vendor

if [ -n "${FFMPEG:-}" ]; then
  cp "$FFMPEG" Vendor/ffmpeg
else
  URL="${FFMPEG_URL:-https://www.osxexperts.net/ffmpeg71arm.zip}"
  TMP="$(mktemp -d)"
  echo "› Downloading $URL"
  curl -fL "$URL" -o "$TMP/ffmpeg.zip"
  unzip -o -q "$TMP/ffmpeg.zip" -d "$TMP"
  find "$TMP" -type f -name ffmpeg -perm -u+x -exec cp {} Vendor/ffmpeg \; -quit
fi

chmod +x Vendor/ffmpeg
xattr -c Vendor/ffmpeg 2>/dev/null || true

# Refuse binaries that link against Homebrew dylibs: they would break on other machines.
if otool -L Vendor/ffmpeg | grep -qE '/(opt/homebrew|usr/local)/'; then
  echo "! Vendor/ffmpeg is not self-contained (links Homebrew libraries)." >&2
  rm Vendor/ffmpeg
  exit 1
fi
Vendor/ffmpeg -hide_banner -version | head -1
echo "› Vendor/ffmpeg ready. Run ./build.sh again to bundle it."
