#!/bin/bash
# Archive and upload a build to TestFlight (internal testing).
#
# Locally: uses the Apple ID signed in to Xcode and DEVELOPMENT_TEAM from Config/Local.xcconfig.
# In CI: set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the .p8) and APPLE_TEAM_ID, and
# Xcode signs with cloud-managed certificates through the App Store Connect API key.
# The build number is a timestamp, so every upload is unique and increasing.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%m%d.%H%M)}"
ARCHIVE="build/Wanderer-$BUILD_NUMBER.xcarchive"

AUTH=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
TEAM=()
if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
  TEAM=(DEVELOPMENT_TEAM="$APPLE_TEAM_ID")
fi

echo "Archiving build $BUILD_NUMBER…"
xcodebuild -project Wanderer.xcodeproj -scheme Wanderer -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${TEAM[@]+"${TEAM[@]}"} \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} archive

echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

echo "Uploaded build $BUILD_NUMBER. It appears in TestFlight after processing (usually 5–15 minutes)."
