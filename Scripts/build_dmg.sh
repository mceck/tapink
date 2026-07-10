#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_PATH=".build/output"
APP_NAME="Drawzee"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="${BUILD_PATH}/${DMG_NAME}"
STAGING_DIR="${BUILD_PATH}/dmg-staging"
RW_DMG="${BUILD_PATH}/${APP_NAME}-rw.dmg"
ICON_PNG="docs/logo.png"
BACKGROUND_PNG="docs/dmg-background.png"   # TODO create bg
ICONSET_DIR="${BUILD_PATH}/${APP_NAME}.iconset"
ICON_ICNS="${BUILD_PATH}/AppIcon.icns"
HELPER="${BUILD_PATH}/set_icon"

WIN_W=660
WIN_H=400
ICON_SIZE=128
APP_ICON_X=180
APP_ICON_Y=190
APPLICATIONS_ICON_X=480
APPLICATIONS_ICON_Y=190

echo "==> Building ${APP_NAME}..."
"$(dirname "$0")/build.sh"

echo "==> Generating .icns from ${ICON_PNG}..."
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"
for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${ICON_PNG}" \
        --out "${ICONSET_DIR}/icon_${size}x${size}.png" > /dev/null 2>&1
    sips -z $((size * 2)) $((size * 2)) "${ICON_PNG}" \
        --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" > /dev/null 2>&1
done
iconutil -c icns "${ICONSET_DIR}" -o "${ICON_ICNS}"
rm -rf "${ICONSET_DIR}"

echo "==> Compiling icon-setter helper..."
cat > "${HELPER}.swift" << 'SWIFT_EOF'
import AppKit
import Foundation

// Usage: set_icon <targetPath> <iconPath>
// targetPath can be a file, folder, or mounted volume root.
let args = CommandLine.arguments
guard args.count >= 3, let image = NSImage(contentsOfFile: args[2]) else {
    exit(1)
}
guard NSWorkspace.shared.setIcon(image, forFile: args[1], options: []) else {
    exit(1)
}
SWIFT_EOF
swiftc -o "${HELPER}" "${HELPER}.swift" -framework AppKit
rm -f "${HELPER}.swift"

echo "==> Creating DMG..."
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"
cp -R "${BUILD_PATH}/${APP_BUNDLE}" "${STAGING_DIR}/${APP_BUNDLE}"
ln -s /Applications "${STAGING_DIR}/Applications"

if [[ -f "${BACKGROUND_PNG}" ]]; then
    mkdir -p "${STAGING_DIR}/.background"
    cp "${BACKGROUND_PNG}" "${STAGING_DIR}/.background/background.png"
fi

DMG_SIZE_MB=$(( $(du -sm "${STAGING_DIR}" | cut -f1) + 50 ))

rm -f "${RW_DMG}"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDRW -fs HFS+ -size "${DMG_SIZE_MB}m" "${RW_DMG}"
rm -rf "${STAGING_DIR}"

echo "==> Configuring window layout, icon and background..."
MOUNT_DIR=$(mktemp -d)
hdiutil attach "${RW_DMG}" -mountroot "${MOUNT_DIR}" -nobrowse
VOLUME_DIR="${MOUNT_DIR}/${APP_NAME}"

cp "${ICON_ICNS}" "${VOLUME_DIR}/.VolumeIcon.icns"
"${HELPER}" "${VOLUME_DIR}" "${ICON_ICNS}"
SetFile -a C "${VOLUME_DIR}" 2>/dev/null || true

osascript <<APPLESCRIPT_EOF
tell application "Finder"
    tell disk "${APP_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 200 + ${WIN_W}, 120 + ${WIN_H}}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to ${ICON_SIZE}
        if exists file ".background:background.png" then
            set background picture of viewOptions to file ".background:background.png"
        end if
        set position of item "${APP_BUNDLE}" of container window to {${APP_ICON_X}, ${APP_ICON_Y}}
        set position of item "Applications" of container window to {${APPLICATIONS_ICON_X}, ${APPLICATIONS_ICON_Y}}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT_EOF

sync
hdiutil detach "${VOLUME_DIR}"
rm -rf "${MOUNT_DIR}"

echo "==> Compressing DMG..."
rm -f "${DMG_PATH}"
hdiutil convert "${RW_DMG}" -ov -format UDZO -imagekey zlib-level=9 -o "${DMG_PATH}"
rm -f "${RW_DMG}"

echo "==> Setting icon on ${DMG_NAME} file..."
"${HELPER}" "${DMG_PATH}" "${ICON_ICNS}"
rm -f "${HELPER}"

echo "==> Done."
echo "    DMG at: ${DMG_PATH}"
echo "    Open with: open ${DMG_PATH}"