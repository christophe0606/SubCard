#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Icon preparation requires macOS sips and iconutil." >&2
    exit 1
fi

# PNG masters and delivery icons are checked in; normal builds only copy them.
# Regenerate delivery formats after changing a master, with temporary files kept
# on the checkout's external volume.
for variant in swiftui gpui; do
    source_png="$SUBCARD_ROOT/assets/icons/sources/mac-$variant.png"
    iconset="$SUBCARD_BUILD/icons/$variant.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$source_png" \
            --out "$iconset/icon_${size}x${size}.png" >/dev/null
        retina=$((size * 2))
        sips -z "$retina" "$retina" "$source_png" \
            --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" \
        -o "$SUBCARD_ROOT/assets/icons/mac-$variant.icns"
done

cp "$SUBCARD_ROOT/assets/icons/sources/iphone.png" \
    "$SUBCARD_ROOT/apps/iphone/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
echo "Prepared macOS .icns files and the iPhone AppIcon image."
