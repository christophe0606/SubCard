#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "The iPhone build requires macOS and Xcode's iOS SDK." >&2
    exit 1
fi
mkdir -p "$SUBCARD_BUILD/iphone" "$SUBCARD_BUILD/apps/iphone"
xcodebuild \
    -project "$SUBCARD_ROOT/apps/iphone/SubCard.xcodeproj" \
    -scheme SubCard-iPhone -configuration Debug \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$SUBCARD_BUILD/iphone/DerivedData" \
    -clonedSourcePackagesDirPath "$SUBCARD_BUILD/iphone/SourcePackages" \
    -packageCachePath "$SUBCARD_BUILD/cache/xcode-packages" \
    -IDEDisablePackageManifestCaching=YES \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
product="$SUBCARD_BUILD/iphone/DerivedData/Build/Products/Debug-iphoneos/SubCard.app"
test -d "$product"
# Replace the generated delivery bundle so removed build outputs cannot linger.
rm -rf "$SUBCARD_BUILD/apps/iphone/SubCard.app"
ditto "$product" "$SUBCARD_BUILD/apps/iphone/SubCard.app"
"$SUBCARD_ROOT/scripts/verify-iphone.sh"
echo "Built unsigned iPhone app: $SUBCARD_BUILD/apps/iphone/SubCard.app"
