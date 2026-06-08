#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ChromeMultiManagerMac"
BUNDLE_ID="life.cryptoreset.chrome-multi-manager.mac"
DISPLAY_NAME="Chrome 多开管理器"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGE_BUNDLE="$DIST_DIR/$DISPLAY_NAME.stage.app"
INSTALL_BUNDLE="$HOME/Applications/$DISPLAY_NAME.app"
LEGACY_INSTALL_BUNDLE="$HOME/Applications/Chrome多开管理器.app"
APP_BUNDLE="$STAGE_BUNDLE"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT_DIR"
APP_VERSION="$(awk -F'"' '/static let version/ { print $2; exit }' Sources/ChromeMultiManagerMac/Support/AppInfo.swift)"
APP_VERSION="${APP_VERSION:-1.0.0}"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
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
sign_app() {
  local bundle="$1"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --deep --sign - "$bundle" >/dev/null
  else
    /usr/bin/codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bundle" >/dev/null
  fi
}

sign_app "$APP_BUNDLE"
/bin/mkdir -p "$HOME/Applications"
/bin/rm -rf "$INSTALL_BUNDLE"
if [[ "$LEGACY_INSTALL_BUNDLE" != "$INSTALL_BUNDLE" ]]; then
  /bin/rm -rf "$LEGACY_INSTALL_BUNDLE"
fi
/usr/bin/ditto --noextattr --noqtn "$APP_BUNDLE" "$INSTALL_BUNDLE"
/usr/bin/xattr -cr "$INSTALL_BUNDLE" >/dev/null 2>&1 || true
sign_app "$INSTALL_BUNDLE"
/bin/rm -rf "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$INSTALL_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
