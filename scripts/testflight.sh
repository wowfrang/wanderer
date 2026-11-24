#!/bin/bash
# Archive and upload a build to TestFlight (internal testing) using Xcode's signed-in account.
# Usage: scripts/testflight.sh
# Needs: Xcode signed in to the Apple ID of your developer team, and DEVELOPMENT_TEAM in
# Config/Local.xcconfig. The build number is a timestamp so every upload is unique.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="$(date +%y%m%d.%H%M)"
ARCHIVE="build/Wanderer-$BUILD_NUMBER.xcarchive"

echo "Archiving build $BUILD_NUMBER…"
xcodebuild -project Wanderer.xcodeproj -scheme Wanderer -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -allowProvisioningUpdates -quiet archive

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates

echo "Uploaded build $BUILD_NUMBER. It appears in TestFlight after processing (usually 5–15 minutes)."
