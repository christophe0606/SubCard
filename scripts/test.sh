#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
source "$(dirname "$0")/environment.sh"
mkdir -p "$SUBCARD_BUILD/tests"
"${CC:-cc}" -std=c11 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION \
    -DSQLITE_DQS=0 -DSQLITE_TEMP_STORE=3 -I "$SUBCARD_ROOT/vendor/sqlite/include" \
    -c "$SUBCARD_ROOT/vendor/sqlite/src/sqlite3.c" -o "$SUBCARD_BUILD/tests/sqlite3.o"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -I "$SUBCARD_ROOT/backend/include" \
    -I "$SUBCARD_ROOT/vendor/sqlite/include" \
    "$SUBCARD_ROOT/tests/document_tests.cpp" "$SUBCARD_ROOT/backend/src/Document.cpp" \
    "$SUBCARD_ROOT/backend/src/UserData.cpp" \
    "$SUBCARD_ROOT/backend/src/SubCardCore.cpp" "$SUBCARD_BUILD/tests/sqlite3.o" \
    -pthread -lm -o "$SUBCARD_BUILD/tests/document-tests"
"$SUBCARD_BUILD/tests/document-tests" "$SUBCARD_BUILD/tests/documents"
"${CXX:-c++}" -std=c++17 -Wall -Wextra -Werror -I "$SUBCARD_ROOT/backend/include" \
    -I "$SUBCARD_ROOT/vendor/sqlite/include" \
    "$SUBCARD_ROOT/tests/document_architecture_tests.cpp" \
    "$SUBCARD_ROOT/backend/src/Document.cpp" "$SUBCARD_ROOT/backend/src/UserData.cpp" \
    "$SUBCARD_ROOT/backend/src/SubCardCore.cpp" "$SUBCARD_BUILD/tests/sqlite3.o" \
    -pthread -lm -o "$SUBCARD_BUILD/tests/document-architecture-tests"
"$SUBCARD_BUILD/tests/document-architecture-tests" "$SUBCARD_BUILD/tests/architecture"
if [[ "$(uname -s)" == Darwin ]]; then
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
