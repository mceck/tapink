#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_PATH=".build/output"
APP_NAME="Drawzee"
APP_BUNDLE="${APP_NAME}.app"
DEST="/Applications/${APP_BUNDLE}"

if [ ! -d "${BUILD_PATH}/${APP_BUNDLE}" ]; then
    echo "Error: ${BUILD_PATH}/${APP_BUNDLE} not found. Run Scripts/build.sh first."
    exit 1
fi

echo "==> Installing to ${DEST}..."
if pgrep -f "/Applications/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
    echo "    Quitting the currently running installed copy..."
    osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
    sleep 1
fi
rm -rf "${DEST}"
cp -R "${BUILD_PATH}/${APP_BUNDLE}" "${DEST}"

echo "==> Installed."
echo "    Launch with: open \"${DEST}\""
echo "    (Start at Login and reliable permission persistence require running from /Applications.)"
