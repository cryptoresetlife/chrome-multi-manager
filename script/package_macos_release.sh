#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ChromeMultiManagerMac"
BUNDLE_ID="life.cryptoreset.chrome-multi-manager.mac"
DISPLAY_NAME="Chrome 多开管理器"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cd "$ROOT_DIR"
APP_VERSION="$(awk -F'"' '/static let version/ { print $2; exit }' Sources/ChromeMultiManagerMac/Support/AppInfo.swift)"
APP_VERSION="${APP_VERSION:-1.0.0}"
ZIP_PATH="$DIST_DIR/${DISPLAY_NAME}_mac_v${APP_VERSION}.zip"
LEGACY_ZIP_PATH="$ROOT_DIR/Chrome多开管理器_mac_发布版.zip"

swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE" "$ZIP_PATH"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "SIGN_IDENTITY is not set; creating an ad-hoc signed macOS test package." >&2
  echo "For public distribution, set SIGN_IDENTITY to a Developer ID Application certificate and notarize." >&2
  /usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"
else
  /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [[ "$SIGN_IDENTITY" != "-" && -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP_BUNDLE" "$ZIP_PATH"
elif [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "NOTARY_PROFILE is not set; created a signed but not notarized zip." >&2
else
  echo "Created an ad-hoc signed zip; users may need to right-click Open." >&2
fi

cp "$ZIP_PATH" "$LEGACY_ZIP_PATH"
echo "$LEGACY_ZIP_PATH"
echo "$ZIP_PATH"
