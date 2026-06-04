#!/usr/bin/env bash
# Downloads static `ffprobe` builds for arm64 and x86_64 and combines them into
# a universal binary at Resources/ffprobe. The result is bundled into the .app
# by build-app.sh, so the running app doesn't depend on a system install.
#
# Sources:
#   - evermeet.cx (Intel x86_64)
#   - osxexperts.net (Apple Silicon arm64)
# Both are long-standing personal-maintainer mirrors of upstream static builds.
# If a URL ever 404s, replace it with another static build and rerun.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="Resources/ffprobe"

if [[ -x "$OUT" ]] && [[ "${FORCE:-}" != "1" ]]; then
  echo "==> $OUT already exists (set FORCE=1 to refetch)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARM_URL="https://www.osxexperts.net/ffprobe71arm.zip"
X86_URL="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"

echo "==> downloading arm64 ffprobe"
curl -fsSL "$ARM_URL" -o "$TMP/arm.zip"
unzip -q -o "$TMP/arm.zip" -d "$TMP/arm"
ARM_BIN="$(find "$TMP/arm" -type f -name ffprobe | head -n 1)"
if [[ -z "$ARM_BIN" ]]; then
  echo "ERROR: couldn't find ffprobe inside $ARM_URL" >&2
  exit 1
fi

echo "==> downloading x86_64 ffprobe"
curl -fsSL "$X86_URL" -o "$TMP/x86.zip"
unzip -q -o "$TMP/x86.zip" -d "$TMP/x86"
X86_BIN="$(find "$TMP/x86" -type f -name ffprobe | head -n 1)"
if [[ -z "$X86_BIN" ]]; then
  echo "ERROR: couldn't find ffprobe inside $X86_URL" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
echo "==> lipo -create -> $OUT"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$OUT"
chmod +x "$OUT"

echo "==> verifying"
file "$OUT"
"$OUT" -version | head -n 1

echo "==> done: $OUT"
