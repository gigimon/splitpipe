#!/usr/bin/env bash
# Builds SplitPipe.app in Release. EXTENSION_VERSION comes from the Makefile (`make package` / `make release`).
#
#   (no options)  Unsigned build packed as build/release/SplitPipe-<version>-macOS.zip with its .sha256. CI uses it
#                 to check that the release configuration builds; a system extension needs a real signature to run,
#                 so this archive does not install.
#   --notarize    Developer ID build packed as build/release/SplitPipe-<version>.dmg with its .sha256: archive, export
#                 for Developer ID (Xcode creates the Developer ID profiles and switches the Network Extension
#                 entitlement to `app-proxy-provider-systemextension`), notarize and staple the app, then the same for
#                 the DMG. Needs a "Developer ID Application" certificate, Xcode signed in to the team, and an App Store
#                 Connect API key: SPLITPIPE_NOTARY_KEY_ID, SPLITPIPE_NOTARY_ISSUER, SPLITPIPE_NOTARY_KEY (path to the
#                 .p8) from the environment or ~/.appstoreconnect/splitpipe-notary.env.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA_PATH="$BUILD_DIR/package"
RELEASE_DIR="$BUILD_DIR/release"
TEAM_ID="BL65NHTRYD"
NOTARIZE="false"
# shellcheck source=resolve_version.sh
source "$ROOT_DIR/scripts/resolve_version.sh"

case "${1:-}" in
  "") ;;
  --notarize) NOTARIZE="true" ;;
  *)
    echo "Usage: scripts/package.sh [--notarize]" >&2
    exit 1
    ;;
esac

if [[ -z "${EXTENSION_VERSION:-}" ]]; then
  echo "error: EXTENSION_VERSION is not set, run it as \`make package\` or \`make release\`" >&2
  exit 1
fi

# Just the file name, so `shasum -c` works next to the downloaded file.
write_checksum() {
  (cd "$(dirname "$1")" && shasum -a 256 "$(basename "$1")") > "$1.sha256"
  echo "Checksum: $1.sha256"
}

cd "$ROOT_DIR"
xcodegen generate --quiet
mkdir -p "$RELEASE_DIR"
VERSION_SETTINGS=(MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" EXTENSION_VERSION="$EXTENSION_VERSION")
echo "Building SplitPipe $APP_VERSION ($BUILD_NUMBER, extension $EXTENSION_VERSION)..."

if [[ "$NOTARIZE" != "true" ]]; then
  ARCHIVE_PATH="$RELEASE_DIR/SplitPipe-$APP_VERSION-macOS.zip"
  APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/SplitPipe.app"
  rm -rf "$DERIVED_DATA_PATH"
  xcodebuild -project SplitPipe.xcodeproj -scheme SplitPipe -configuration Release \
    -destination "platform=macOS" -derivedDataPath "$DERIVED_DATA_PATH" "${VERSION_SETTINGS[@]}" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
    build
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: expected app bundle was not produced: $APP_PATH" >&2
    exit 1
  fi
  rm -f "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
  ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
  echo "Archive: $ARCHIVE_PATH"
  write_checksum "$ARCHIVE_PATH"
  exit 0
fi

NOTARY_ENV="$HOME/.appstoreconnect/splitpipe-notary.env"
if [[ -z "${SPLITPIPE_NOTARY_KEY_ID:-}" && -f "$NOTARY_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$NOTARY_ENV"
fi
for variable in SPLITPIPE_NOTARY_KEY_ID SPLITPIPE_NOTARY_ISSUER SPLITPIPE_NOTARY_KEY; do
  if [[ -z "${!variable:-}" ]]; then
    echo "error: $variable is not set (see the header of this script)" >&2
    exit 1
  fi
done
if [[ ! -f "$SPLITPIPE_NOTARY_KEY" ]]; then
  echo "error: API key not found: $SPLITPIPE_NOTARY_KEY" >&2
  exit 1
fi
NOTARY_AUTH=(--key "$SPLITPIPE_NOTARY_KEY" --key-id "$SPLITPIPE_NOTARY_KEY_ID" --issuer "$SPLITPIPE_NOTARY_ISSUER")

WORK_DIR="$BUILD_DIR/notarize"
XCARCHIVE="$WORK_DIR/SplitPipe.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
APP_PATH="$EXPORT_DIR/SplitPipe.app"
DMG_PATH="$RELEASE_DIR/SplitPipe-$APP_VERSION.dmg"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

xcodebuild archive -project SplitPipe.xcodeproj -scheme SplitPipe -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$XCARCHIVE" -allowProvisioningUpdates "${VERSION_SETTINGS[@]}"

cat > "$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$XCARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" -allowProvisioningUpdates

SIGNATURE="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 || true)"
if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
  echo "error: $APP_PATH isn't signed with Developer ID" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

# Submits a file and waits; on rejection prints Apple's log.
notarize() {
  local result status id
  echo "Notarizing $(basename "$1")..."
  result="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --timeout 30m --output-format json || true)"
  status="$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - - <<< "$result" 2>/dev/null || true)"
  echo "Notarization $id: ${status:-no answer}"
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2
    exit 1
  fi
}

# The app gets its own ticket so it opens offline after being copied out of the DMG.
ditto -c -k --keepParent "$APP_PATH" "$WORK_DIR/SplitPipe-notarization.zip"
notarize "$WORK_DIR/SplitPipe-notarization.zip"
xcrun stapler staple "$APP_PATH"
spctl --assess --type execute -vv "$APP_PATH"

DMG_ROOT="$WORK_DIR/dmg"
mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/SplitPipe.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG_PATH" "$DMG_PATH.sha256"
hdiutil create -volname "SplitPipe" -srcfolder "$DMG_ROOT" -format UDZO -ov "$DMG_PATH"
codesign --sign "Developer ID Application" --timestamp "$DMG_PATH"
notarize "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"

echo "DMG: $DMG_PATH"
write_checksum "$DMG_PATH"
