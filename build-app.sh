#!/usr/bin/env bash
# Build MovieStats as a proper .app bundle so macOS treats it as a regular
# windowed app. Works with just the Command Line Tools — no full Xcode needed.
# Output: ./MovieStats.app
set -euo pipefail

CONFIG="${CONFIG:-release}"
APP_NAME="MovieStats"
BUNDLE_ID="com.python21.MovieStats"
APP_DIR="${APP_NAME}.app"

cd "$(dirname "$0")"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# App icon. Generate it first with ./make-icon.sh if it's missing.
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/AppIcon.icns"
else
  echo "WARNING: Resources/AppIcon.icns not found — run ./make-icon.sh" >&2
fi

# Bundled ffprobe — used to read codec/resolution/HDR/track info per movie.
if [[ ! -x Resources/ffprobe ]]; then
  echo "==> fetching ffprobe (one-time)"
  ./Tools/fetch-ffprobe.sh
fi
cp Resources/ffprobe "${APP_DIR}/Contents/Resources/ffprobe"
chmod +x "${APP_DIR}/Contents/Resources/ffprobe"

cat >"${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>Movie Stats</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.video</string>
  <key>NSHumanReadableCopyright</key>
  <string>© $(date +%Y) Andrew Nowicki</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
</dict>
</plist>
PLIST

# Ad-hoc signature is enough for a personal, non-distributed app.
# Sign the nested ffprobe first so the outer bundle's signature stays valid.
echo "==> codesigning (ad-hoc)"
codesign --force --sign - "${APP_DIR}/Contents/Resources/ffprobe"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}"

echo "==> done: $(pwd)/${APP_DIR}"
echo "    run it with:  open ${APP_DIR}"
