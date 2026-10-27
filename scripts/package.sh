#!/usr/bin/env bash
# Builds SplitPipe.app in Release and packs build/release/SplitPipe-<version>-macOS.zip with its .sha256.
# The app is not signed: CI uses it to check that the release configuration builds. A system extension needs a
# real signature to run, so this archive does not install. EXTENSION_VERSION comes from the Makefile (`make package`).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA_PATH="$BUILD_DIR/package"
RELEASE_DIR="$BUILD_DIR/release"
# shellcheck source=resolve_version.sh
source "$ROOT_DIR/scripts/resolve_version.sh"

if [[ -z "${EXTENSION_VERSION:-}" ]]; then
  echo "error: EXTENSION_VERSION is not set, run it as \`make package\`" >&2
  exit 1
fi

ARCHIVE_PATH="$RELEASE_DIR/SplitPipe-$APP_VERSION-macOS.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/SplitPipe.app"

cd "$ROOT_DIR"
xcodegen generate --quiet
rm -rf "$DERIVED_DATA_PATH"

echo "Building SplitPipe $APP_VERSION ($BUILD_NUMBER, extension $EXTENSION_VERSION)..."
xcodebuild -project SplitPipe.xcodeproj -scheme SplitPipe -configuration Release \
  -destination "platform=macOS" -derivedDataPath "$DERIVED_DATA_PATH" \
  MARKETING_VERSION="$APP_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" EXTENSION_VERSION="$EXTENSION_VERSION" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app bundle was not produced: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$RELEASE_DIR"
rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
# Just the file name, so `shasum -c` works next to the downloaded archive.
(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$ARCHIVE_PATH")") > "$CHECKSUM_PATH"

echo "Archive: $ARCHIVE_PATH"
echo "Checksum: $CHECKSUM_PATH"
