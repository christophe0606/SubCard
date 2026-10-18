#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./scripts/run-iphone.sh --device IPHONE_UDID [--no-launch]
       ./scripts/run.sh iphone --device IPHONE_UDID [--no-launch]

Rebuild, development-sign, install, and launch SubCard on a physical iPhone
without opening Xcode. The iPhone must trust this Mac, have Developer Mode
enabled, and be unlocked for launch.

  --device UDID   Physical iPhone UDID (or set SUBCARD_IPHONE_UDID).
  --no-launch     Install the rebuilt app without launching it.
  -h, --help      Show this help.

Requires the same environment as sign-iphone.sh:
  SUBCARD_TEAM_ID, SUBCARD_BUNDLE_ID, SUBCARD_SIGNING_IDENTITY

Find your iPhone with: xcrun devicectl list devices
Use its hardware UDID, which both xcodebuild and devicectl accept.
Build products and caches stay in the checkout's .build/ directory.
USAGE
}

device="${SUBCARD_IPHONE_UDID:-}"
launch=yes
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "Missing value for --device (see --help)." >&2
                exit 2
            fi
            device="$2"
            shift 2
            ;;
        --no-launch) launch=no; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1 (see --help)." >&2; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != Darwin ]]; then
    echo "iPhone deployment requires macOS and Xcode's command-line tools." >&2
    exit 1
fi
if [[ -z "$device" ]]; then
    echo "Specify --device IPHONE_UDID or export SUBCARD_IPHONE_UDID (see --help)." >&2
    exit 2
fi
for variable in SUBCARD_TEAM_ID SUBCARD_BUNDLE_ID SUBCARD_SIGNING_IDENTITY; do
    if [[ -z "${!variable:-}" ]]; then
        echo "Set and export $variable before deployment (see --help)." >&2
        exit 2
    fi
done

source "$(dirname "$0")/environment.sh"
# Check connectivity before spending time rebuilding; no device is picked silently.
xcrun devicectl device info details --device "$device" --timeout 30 --quiet
"$SUBCARD_ROOT/scripts/sign-iphone.sh" --device "$device"

delivery="$SUBCARD_BUILD/apps/iphone-signed/SubCard.app"
xcrun devicectl device install app --device "$device" "$delivery" --timeout 60
echo "SubCard installed on the selected iPhone."
if [[ "$launch" == yes ]]; then
    xcrun devicectl device process launch --device "$device" \
        --timeout 30 "$SUBCARD_BUNDLE_ID"
    echo "SubCard launched on the selected iPhone."
fi
