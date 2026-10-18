#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
mkdir -p "$SUBCARD_BUILD/tests"
"${CC:-cc}" -std=c11 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION \
    -DSQLITE_DQS=0 -DSQLITE_TEMP_STORE=3 -I "$SUBCARD_ROOT/vendor/sqlite/include" \
    -c "$SUBCARD_ROOT/vendor/sqlite/src/sqlite3.c" -o "$SUBCARD_BUILD/tests/sqlite3.o"
core_objects=("$SUBCARD_BUILD/tests/sqlite3.o")
for source in Document UserData CheckExpression ERModel SubCardCore; do
    object="$SUBCARD_BUILD/tests/$source.o"
    "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -I "$SUBCARD_ROOT/backend/include" \
        -I "$SUBCARD_ROOT/vendor/sqlite/include" -c "$SUBCARD_ROOT/backend/src/$source.cpp" -o "$object"
    core_objects+=("$object")
done
for suite in document document_architecture er_model; do
    "${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -I "$SUBCARD_ROOT/backend/include" \
        -I "$SUBCARD_ROOT/vendor/sqlite/include" "$SUBCARD_ROOT/tests/${suite}_tests.cpp" \
        "${core_objects[@]}" -pthread -lm -o "$SUBCARD_BUILD/tests/$suite-tests"
    "$SUBCARD_BUILD/tests/$suite-tests" "$SUBCARD_BUILD/tests/$suite"
done
if [[ "$(uname -s)" == Darwin ]]; then
    swiftc -module-cache-path "$SWIFT_MODULECACHE_PATH" \
        "$SUBCARD_ROOT/apps/swiftui/ERViewport.swift" "$SUBCARD_ROOT/tests/er_viewport_tests.swift" \
        -o "$SUBCARD_BUILD/tests/er-viewport-tests"
    "$SUBCARD_BUILD/tests/er-viewport-tests"
    # Compile the real frontend store against the same shared backend objects.
    # Generate this absolute-path module map only in external build output.
    cat > "$SUBCARD_BUILD/tests/SubCardCore.modulemap" <<MODULE
module SubCardCore {
    umbrella header "$SUBCARD_ROOT/backend/include/SubCardCore.h"
    export *
}
MODULE
    swiftc -parse-as-library \
        -module-cache-path "$SWIFT_MODULECACHE_PATH" \
        -Xcc "-fmodule-map-file=$SUBCARD_BUILD/tests/SubCardCore.modulemap" \
        "$SUBCARD_ROOT/apps/swiftui/ERStore.swift" "$SUBCARD_ROOT/apps/swiftui/ERViewport.swift" \
        "$SUBCARD_ROOT/tests/er_editor_tests.swift" "${core_objects[@]}" -Xlinker -lc++ \
        -o "$SUBCARD_BUILD/tests/er-editor-tests"
    "$SUBCARD_BUILD/tests/er-editor-tests"
    for variant in swiftui gpui; do
        executable="$SUBCARD_BUILD/apps/$variant/SubCard.app/Contents/MacOS/SubCard"
        if [[ -f "$executable" ]]; then
            dependencies="$(otool -L "$executable")"
            while IFS= read -r dependency; do
                case "$dependency" in
                    /usr/lib/*|/System/Library/*) ;;
                    *) echo "Unexpected non-system runtime dependency: $dependency" >&2; exit 1 ;;
                esac
            done < <(printf '%s\n' "$dependencies" | awk 'NR > 1 { print $1 }')
            codesign --verify --strict "$SUBCARD_BUILD/apps/$variant/SubCard.app"
            echo "$variant runtime dependencies: system libraries/frameworks only."
        fi
    done
fi
if [[ "$(uname -s)" == Darwin && -d "$SUBCARD_BUILD/apps/iphone/SubCard.app" ]]; then
    "$SUBCARD_ROOT/scripts/verify-iphone.sh"
fi
