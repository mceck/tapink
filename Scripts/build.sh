#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_PATH=".build/output"
mkdir -p $BUILD_PATH

APP_NAME="TapInk"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Building ${APP_NAME} (release)..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${BUILD_PATH}/${APP_BUNDLE}..."
rm -rf "${BUILD_PATH}/${APP_BUNDLE}"
mkdir -p "${BUILD_PATH}/${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${BUILD_PATH}/${APP_BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${BUILD_PATH}/${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUILD_PATH}/${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/CameraShutter.wav" "${BUILD_PATH}/${APP_BUNDLE}/Contents/Resources/CameraShutter.wav"
cp "Resources/AppIcon.icns" "${BUILD_PATH}/${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Code signing..."
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
    echo "    Using signing identity: ${IDENTITY}"
else
    echo "    WARNING: no 'Apple Development' identity found in your keychain."
    echo "    Falling back to ad-hoc signing (--sign -). The app will run fine, but"
    echo "    macOS may ask you to re-grant Screen Recording / Accessibility permissions"
    echo "    after every rebuild, since ad-hoc signatures have no stable identity."
    echo "    Fix: open Xcode > Settings > Accounts, sign in with your Apple ID (free"
    echo "    Personal Team is enough), then re-run this script."
fi

codesign --force --sign "${IDENTITY}" --entitlements "Resources/TapInk.entitlements" "${BUILD_PATH}/${APP_BUNDLE}"

echo "==> Done."
echo "    Run with:      open ${BUILD_PATH}/${APP_BUNDLE}"
echo "    Install with:  Scripts/install.sh   (recommended for Start at Login to work)"
