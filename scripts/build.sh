#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"

bundle_macos() {
    local variant="$1" executable="$2"
    local bundle="$SUBCARD_BUILD/apps/$variant/SubCard.app"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp "$executable" "$bundle/Contents/MacOS/SubCard"
    cp "$SUBCARD_ROOT/assets/icons/mac-$variant.icns" \
        "$bundle/Contents/Resources/SubCard.icns"
    cp "$SUBCARD_ROOT/LICENSE" "$SUBCARD_ROOT/THIRD_PARTY_NOTICES.md" \
        "$bundle/Contents/Resources/"
    cp -R "$SUBCARD_ROOT/licenses" "$bundle/Contents/Resources/"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>SubCard</string>
    <key>CFBundleName</key><string>SubCard</string>
    <key>CFBundleIconFile</key><string>SubCard.icns</string>
    <key>CFBundleDisplayName</key><string>SubCard</string>
    <key>CFBundleIdentifier</key><string>org.subcard.$variant</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>UTExportedTypeDeclarations</key><array><dict>
        <key>UTTypeIdentifier</key><string>org.subcard.document</string>
        <key>UTTypeDescription</key><string>SubCard Document</string>
        <key>UTTypeConformsTo</key><array><string>public.database</string></array>
        <key>UTTypeTagSpecification</key><dict>
            <key>public.filename-extension</key><array><string>subcard</string></array>
            <key>public.mime-type</key><string>application/vnd.subcard+sqlite3</string>
        </dict>
    </dict></array>
</dict></plist>
PLIST
    codesign --force --sign - "$bundle"
    # Updating files inside Contents does not update the enclosing .app's date.
    # Let Launch Services notice changed metadata/resources on the next launch.
    touch "$bundle"
    echo "Built $bundle"
}

build_swiftui() {
    if [[ "$(uname -s)" != Darwin ]]; then
        echo "SwiftUI requires macOS and Xcode." >&2
        return 1
    fi
    local swift_options=(
        --package-path "$SUBCARD_ROOT"
        --scratch-path "$SUBCARD_BUILD/swiftui"
        --cache-path "$SUBCARD_BUILD/cache/swiftpm"
        --config-path "$SUBCARD_BUILD/swiftpm/config"
        --security-path "$SUBCARD_BUILD/swiftpm/security"
        --disable-sandbox
    )
    swift build "${swift_options[@]}"
    local bin_dir
    bin_dir="$(swift build "${swift_options[@]}" --show-bin-path)"
    bundle_macos swiftui "$bin_dir/SubCard"
}

build_gpui() {
    cargo build --locked --manifest-path "$SUBCARD_ROOT/apps/gpui/Cargo.toml"
    if [[ "$(uname -s)" == Darwin ]]; then
        bundle_macos gpui "$CARGO_TARGET_DIR/debug/subcard-gpui"
    else
        echo "Built $CARGO_TARGET_DIR/debug/subcard-gpui"
    fi
}

case "${1:-all}" in
    swiftui) build_swiftui ;;
    gpui) build_gpui ;;
    iphone) "$SUBCARD_ROOT/scripts/build-iphone.sh" ;;
    all) build_swiftui; build_gpui ;;
    *) echo "Usage: $0 [swiftui|gpui|iphone|all] (all builds both desktop versions)" >&2; exit 2 ;;
esac
