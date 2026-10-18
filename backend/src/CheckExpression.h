// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <string>
#include <utility>
#include <vector>

namespace subcard {
// Rewrites identifier tokens only, preserving SQL string literals and functions.
std::string rewrite_check(const std::string& expression,
    const std::vector<std::pair<std::string, std::string>>& identifiers);
std::string sql_identifier(const std::string& name);
// Compiles an actual CHECK with SQLite on a disposable in-memory database.
// Never evaluates user expressions or changes the document.
void validate_check_sql(const std::string& expression, const std::vector<std::string>& columns);
bool allowed_user_function(const char* name);
}
