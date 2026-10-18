#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Source this file from the build/run scripts. Paths follow the checkout.
SUBCARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBCARD_BUILD="$SUBCARD_ROOT/.build"

# Explicitly redirect dependency downloads, compiler caches and temporary files
# to the checkout (on the external volume on the development Mac).
export CARGO_HOME="$SUBCARD_BUILD/cargo-home"
export CARGO_TARGET_DIR="$SUBCARD_BUILD/gpui"
export CLANG_MODULE_CACHE_PATH="$SUBCARD_BUILD/cache/clang"
export SWIFT_MODULECACHE_PATH="$SUBCARD_BUILD/cache/swift"
export SWIFTPM_MODULECACHE_OVERRIDE="$SUBCARD_BUILD/cache/swiftpm-modules"
export XDG_CACHE_HOME="$SUBCARD_BUILD/cache"
export TMPDIR="$SUBCARD_BUILD/tmp"
mkdir -p "$CARGO_HOME" "$CARGO_TARGET_DIR" "$CLANG_MODULE_CACHE_PATH" \
    "$SWIFT_MODULECACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$TMPDIR"
