#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./scripts/sign-iphone.sh [--device UDID]

Build and development-sign SubCard for a physical iPhone. Requires an Apple
account already signed into Xcode. Does not install or launch the application.

  --device UDID   Target a connected iPhone and allow its registration with Apple.
                  Without this option, use a generic iOS destination and devices
                  already registered with your team.
  -h, --help      Show this help.

Required environment variables (no account-specific defaults):
  SUBCARD_TEAM_ID           Your signing team's 10-character identifier.
  SUBCARD_BUNDLE_ID         Your app's reverse-DNS bundle identifier.
  SUBCARD_SIGNING_IDENTITY  Keychain signing identity name or certificate hash.

Find your connected iPhone's UDID with: xcrun xctrace list devices
All project-controlled build files are stored under the checkout's .build/.
Xcode manages credentials, certificates, and profiles in its usual locations.
USAGE
}

team="${SUBCARD_TEAM_ID:-}"
bundle_id="${SUBCARD_BUNDLE_ID:-}"
signing_identity="${SUBCARD_SIGNING_IDENTITY:-}"
device=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --device)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "Missing value for $1" >&2
                exit 2
            fi
            device="$2"
            shift 2
            ;;
        *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
done

for variable in SUBCARD_TEAM_ID SUBCARD_BUNDLE_ID SUBCARD_SIGNING_IDENTITY; do
    if [[ -z "${!variable:-}" ]]; then
        echo "Set and export $variable before signing (see --help)." >&2
        exit 2
    fi
done

if [[ "$(uname -s)" != Darwin ]]; then
    echo "iPhone signing requires macOS and Xcode's iOS SDK." >&2
    exit 1
fi
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "The team ID must contain 10 uppercase letters or digits." >&2
    exit 2
fi
if [[ ! "$bundle_id" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo "Use a reverse-DNS bundle identifier, such as com.example.SubCard." >&2
    exit 2
fi

source "$(dirname "$0")/environment.sh"
signed_build="$SUBCARD_BUILD/iphone-signed"
delivery="$SUBCARD_BUILD/apps/iphone-signed/SubCard.app"
mkdir -p "$signed_build" "$(dirname "$delivery")"

destination='generic/platform=iOS'
provisioning_flags=(-allowProvisioningUpdates)
if [[ -n "$device" ]]; then
    destination="platform=iOS,id=$device"
    provisioning_flags+=(-allowProvisioningDeviceRegistration)
fi

echo "Building and signing $bundle_id with team $team."
echo "Automatic signing may create development certificates and profiles with Apple."
xcodebuild \
    -project "$SUBCARD_ROOT/apps/iphone/SubCard.xcodeproj" \
    -scheme SubCard-iPhone -configuration Debug \
    -sdk iphoneos -destination "$destination" \
    -derivedDataPath "$signed_build/DerivedData" \
    -clonedSourcePackagesDirPath "$signed_build/SourcePackages" \
    -packageCachePath "$SUBCARD_BUILD/cache/xcode-packages" \
    -IDEDisablePackageManifestCaching=YES \
    -disableAutomaticPackageResolution \
    "${provisioning_flags[@]}" \
    DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="$signing_identity" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES build

product="$signed_build/DerivedData/Build/Products/Debug-iphoneos/SubCard.app"
"$SUBCARD_ROOT/scripts/verify-iphone.sh" "$product"
test -f "$product/embedded.mobileprovision"
codesign --verify --deep --strict --verbose=2 "$product"
actual_team="$(codesign -d --verbose=4 "$product" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2 }')"
if [[ "$actual_team" != "$team" ]]; then
    echo "Signed app team '$actual_team' does not match requested team '$team'." >&2
    exit 1
fi

# Replace only the generated signed delivery bundle after verification succeeds.
rm -rf "$delivery"
ditto "$product" "$delivery"
codesign --verify --deep --strict --verbose=2 "$delivery"
echo "Signed iPhone app: $delivery"
