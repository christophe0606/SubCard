#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
variant="${1:-swiftui}"
case "$variant" in
    swiftui|gpui) ;;
    iphone) shift; exec "$SUBCARD_ROOT/scripts/run-iphone.sh" "$@" ;;
    *) echo "Usage: $0 [swiftui|gpui|iphone] (iphone: --device IPHONE_UDID [--no-launch])" >&2; exit 2 ;;
esac
"$SUBCARD_ROOT/scripts/build.sh" "$variant"
if [[ "$(uname -s)" == Darwin ]]; then
    bundle="$SUBCARD_BUILD/apps/$variant/SubCard.app"
    # These development bundles keep their identity/path between rebuilds.
    # Refresh only this app's registration before launch so a cached generic
    # icon from an earlier build is not retained by Launch Services.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$bundle"
    open "$bundle"
else
    exec "$CARGO_TARGET_DIR/debug/subcard-gpui"
fi
