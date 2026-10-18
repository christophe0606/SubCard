#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Icon preparation requires macOS and Xcode's actool." >&2
    exit 1
fi

# PNG masters and delivery icons are checked in; normal builds only copy them.
# Regenerate delivery formats after changing a master, with temporary files kept
# on the checkout's external volume.
for variant in swiftui gpui; do
    source_png="$SUBCARD_ROOT/assets/icons/sources/mac-$variant.png"
    composition="$SUBCARD_BUILD/icons/$variant/SubCard.icon"
    output="$SUBCARD_BUILD/icons/$variant/compiled"
    mkdir -p "$composition/Assets" "$output"
    cp "$source_png" "$composition/Assets/Artwork.png"
    cp "$SUBCARD_ROOT/assets/icons/macos-composition.json" "$composition/icon.json"
    # The native enclosure prevents Tahoe from putting the legacy artwork into
    # a gray fallback tile. actool also exports an .icns for older macOS.
    xcrun actool "$composition" --compile "$output" \
        --output-format human-readable-text --platform macosx \
        --minimum-deployment-target 14.0 --target-device mac --app-icon SubCard \
        --output-partial-info-plist "$SUBCARD_BUILD/icons/$variant/icon-info.plist"
    cp "$output/SubCard.icns" "$SUBCARD_ROOT/assets/icons/mac-$variant.icns"
    cp "$output/Assets.car" "$SUBCARD_ROOT/assets/icons/mac-$variant.car"
done

cp "$SUBCARD_ROOT/assets/icons/sources/iphone.png" \
    "$SUBCARD_ROOT/apps/iphone/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
echo "Prepared macOS native catalogs, fallback .icns files and the iPhone AppIcon image."
