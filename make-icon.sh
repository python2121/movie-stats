#!/usr/bin/env bash
# Generates the app icon: renders a 1024px master PNG with the CoreGraphics
# icon generator, then builds Resources/AppIcon.icns (all required sizes).
# Re-run this whenever the icon design changes. Needs only Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

MASTER="Resources/AppIcon.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
ICNS="Resources/AppIcon.icns"

mkdir -p Resources "${ICONSET}"

echo "==> rendering master PNG"
swiftc -O Tools/icon-generator/main.swift -o /tmp/movie-stats-icon-generator
/tmp/movie-stats-icon-generator "${MASTER}"

echo "==> generating iconset sizes"
gen() { sips -z "$1" "$1" "${MASTER}" --out "${ICONSET}/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

echo "==> building ${ICNS}"
iconutil --convert icns "${ICONSET}" --output "${ICNS}"
rm -rf "$(dirname "${ICONSET}")"

echo "==> done: ${ICNS}"
