#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
app="${1:-$SUBCARD_BUILD/apps/iphone/SubCard.app}"
binary="$app/SubCard"
test -f "$binary"
test -f "$app/LICENSE"
test -f "$app/THIRD_PARTY_NOTICES.md"
test -f "$app/Assets.car"
test -f "$app/AppIcon60x60@2x.png"
# Other scales can be stored only in Assets.car by the asset compiler.
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$app/Info.plist")" = AppIcon
test "$(lipo -archs "$binary")" = arm64
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$app/Info.plist")" = iPhoneOS
test "$(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:0' "$app/Info.plist")" = 1
test "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")" = 16.0
mkdir -p "$SUBCARD_BUILD/iphone"
xcrun vtool -show-build "$binary" > "$SUBCARD_BUILD/iphone/platform.txt"
awk '$1 == "platform" && $2 == "IOS" { ios = 1 }
     $1 == "minos" && $2 == "16.0" { compatible = 1 }
     END { exit !(ios && compatible) }' "$SUBCARD_BUILD/iphone/platform.txt"
dependencies="$(otool -L "$binary")"
while IFS= read -r dependency; do
    case "$dependency" in
        *libsqlite*) echo "Unexpected dynamic SQLite dependency: $dependency" >&2; exit 1 ;;
        /usr/lib/*|/System/Library/*) ;;
        *) echo "Unexpected non-system iPhone dependency: $dependency" >&2; exit 1 ;;
    esac
done < <(printf '%s\n' "$dependencies" | awk 'NR > 1 { print $1 }')
plutil -lint "$app/Info.plist"
echo "Verified arm64 iPhoneOS app with AppIcon catalog and iOS 16.0 minimum; system runtime dependencies only, no SQLite dylib."
