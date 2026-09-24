#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
PACKAGE_DIRECTORY="$REPOSITORY_ROOT/Packages/NinevehReaderKit"
BUILD_DIRECTORY="$REPOSITORY_ROOT/.build/local-release"
OUTPUT_DIRECTORY="$REPOSITORY_ROOT/dist"
APP_BUNDLE="$OUTPUT_DIRECTORY/Nineveh Reader.app"
ZIP_ARCHIVE="$OUTPUT_DIRECTORY/Nineveh Reader.zip"

SWIFT_ARGUMENTS=(
  build
  --package-path "$PACKAGE_DIRECTORY"
  --scratch-path "$BUILD_DIRECTORY"
  --configuration release
  --product NinevehReaderApp
)

if [[ "${NINEVEH_DISABLE_SWIFT_SANDBOX:-0}" == "1" ]]; then
  SWIFT_ARGUMENTS+=(--disable-sandbox)
fi

swift "${SWIFT_ARGUMENTS[@]}"

BIN_ARGUMENTS=(
  build
  --package-path "$PACKAGE_DIRECTORY"
  --scratch-path "$BUILD_DIRECTORY"
  --configuration release
  --show-bin-path
)

if [[ "${NINEVEH_DISABLE_SWIFT_SANDBOX:-0}" == "1" ]]; then
  BIN_ARGUMENTS+=(--disable-sandbox)
fi

BINARY_DIRECTORY="$(swift "${BIN_ARGUMENTS[@]}")"
BINARY_PATH="$BINARY_DIRECTORY/NinevehReaderApp"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "The release executable was not produced at $BINARY_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIRECTORY"
if [[ -e "$APP_BUNDLE" ]]; then
  rm -rf "$APP_BUNDLE"
fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

ditto "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/Nineveh Reader"
ditto "$REPOSITORY_ROOT/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
ditto "$REPOSITORY_ROOT/App/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
ditto "$REPOSITORY_ROOT/App/ThirdPartyNotices.txt" "$APP_BUNDLE/Contents/Resources/ThirdPartyNotices.txt"

plutil -replace CFBundleDevelopmentRegion -string en "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleExecutable -string "Nineveh Reader" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.nineveh.reader "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIconFile -string AppIcon "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIconName -string AppIcon "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleName -string "Nineveh Reader" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 1.0 "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string 1 "$APP_BUNDLE/Contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string 15.0 "$APP_BUNDLE/Contents/Info.plist"

xcrun actool "$REPOSITORY_ROOT/App/Assets.xcassets" \
  --compile "$APP_BUNDLE/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --output-partial-info-plist "$BUILD_DIRECTORY/asset-info.plist"

if [[ -d "$BINARY_DIRECTORY/ZIPFoundation_ZIPFoundation.bundle" ]]; then
  ditto \
    "$BINARY_DIRECTORY/ZIPFoundation_ZIPFoundation.bundle" \
    "$APP_BUNDLE/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle"
fi

codesign \
  --force \
  --sign - \
  --options runtime \
  --entitlements "$REPOSITORY_ROOT/App/NinevehReader.entitlements" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

if [[ -e "$ZIP_ARCHIVE" ]]; then
  rm -f "$ZIP_ARCHIVE"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_ARCHIVE"

echo "Built: $APP_BUNDLE"
echo "Archive: $ZIP_ARCHIVE"
