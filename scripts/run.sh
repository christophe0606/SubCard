#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
variant="${1:-swiftui}"
case "$variant" in
    swiftui|gpui) ;;
    *) echo "Usage: $0 [swiftui|gpui]" >&2; exit 2 ;;
esac
"$SUBCARD_ROOT/scripts/build.sh" "$variant"
if [[ "$(uname -s)" == Darwin ]]; then
    open "$SUBCARD_BUILD/apps/$variant/SubCard.app"
else
    exec "$CARGO_TARGET_DIR/debug/subcard-gpui"
fi
