// SPDX-License-Identifier: Apache-2.0
#include "CheckExpression.h"
#include "UTF8.h"
#include "sqlite3.h"
#include <cctype>
#include <memory>
#include <stdexcept>

namespace subcard {
std::string sql_identifier(const std::string& name) {
    std::string result = "\"";
    for (char c : name) { result += c; if (c == '"') result += c; }
    return result + "\"";
}
bool allowed_user_function(const char* name) {
    for (const char* allowed : {"abs", "coalesce", "ifnull", "iif", "length", "octet_length",
        "lower", "upper", "ltrim", "rtrim", "trim", "min", "max", "count", "sum", "nullif",
        "replace", "round", "sign", "date", "time", "datetime", "julianday", "unixepoch",
        "strftime", "substr", "substring", "hex", "unhex", "glob", "like", "instr", "char",
        "unicode", "typeof", "quote", "printf", "format"})
        if (name && sqlite3_stricmp(name, allowed) == 0) return true;
    return false;
}
std::string rewrite_check(const std::string& expression,
    const std::vector<std::pair<std::string, std::string>>& identifiers) {
    if (expression.size() > 4096 || expression.find('\0') != std::string::npos || !valid_utf8(expression))
        throw std::runtime_error("CHECK expressions must be valid UTF-8 and at most 4096 bytes.");
    auto start = [](unsigned char c) { return std::isalpha(c) || c == '_' || c >= 128; };
    auto part = [&](unsigned char c) { return start(c) || std::isdigit(c) || c == '$'; };
    std::string result;
    std::string previousWord;
    int depth = 0;
    for (size_t i = 0; i < expression.size();) {
        const auto begin = i;
        const char c = expression[i];
        if (c == ';' || c == '?' || c == ':' || c == '@' || c == '$' ||
            (i + 1 < expression.size() && ((c == '-' && expression[i + 1] == '-') ||
                                         (c == '/' && expression[i + 1] == '*'))))
            throw std::runtime_error("Enter one expression, without SQL statements, comments or parameters.");
        if (c == '(') ++depth;
        if (c == ')' && --depth < 0) throw std::runtime_error("Unbalanced parentheses in CHECK expression.");
        if (c == '\'' || c == '"' || c == '`' || c == '[') {
            const char end = c == '[' ? ']' : c;
            std::string token;
            bool closed = false;
            ++i;
            while (i < expression.size()) {
                if (expression[i] == end) {
                    ++i;
                    if (c != '[' && i < expression.size() && expression[i] == end) { token += end; ++i; }
                    else { closed = true; break; }
                } else token += expression[i++];
            }
            if (!closed) throw std::runtime_error("Unterminated quote in CHECK expression.");
            bool replaced = false;
            size_t next = expression.find_first_not_of(" \t\r\n", i);
            if (c != '\'' && previousWord != "as" && previousWord != "collate" &&
                (next == std::string::npos || expression[next] != '('))
                for (const auto& entry : identifiers)
                    if (sqlite3_stricmp(token.c_str(), entry.first.c_str()) == 0) {
                        result += entry.second; replaced = true; break;
                    }
            if (!replaced) result += expression.substr(begin, i - begin);
            previousWord.clear();
        } else if (std::isdigit(static_cast<unsigned char>(c)) ||
                   (c == '.' && i + 1 < expression.size() && std::isdigit(static_cast<unsigned char>(expression[i + 1])))) {
            ++i;
            while (i < expression.size()) {
                const char n = expression[i];
                if (std::isalnum(static_cast<unsigned char>(n)) || n == '_' || n == '.' ||
                    ((n == '+' || n == '-') && (expression[i - 1] == 'e' || expression[i - 1] == 'E'))) ++i;
                else break;
            }
            result += expression.substr(begin, i - begin);
            previousWord.clear();
        } else if (start(static_cast<unsigned char>(c))) {
            while (i < expression.size() && part(static_cast<unsigned char>(expression[i]))) ++i;
            const auto token = expression.substr(begin, i - begin);
            const auto next = expression.find_first_not_of(" \t\r\n", i);
            bool replaced = false;
            if (previousWord != "as" && previousWord != "collate" &&
                !sqlite3_keyword_check(token.c_str(), static_cast<int>(token.size())) &&
                sqlite3_stricmp(token.c_str(), "true") != 0 && sqlite3_stricmp(token.c_str(), "false") != 0 &&
                (next == std::string::npos || expression[next] != '(') &&
                !(token.size() == 1 && (token[0] == 'x' || token[0] == 'X') && i < expression.size() && expression[i] == '\''))
                for (const auto& entry : identifiers)
                    if (sqlite3_stricmp(token.c_str(), entry.first.c_str()) == 0) {
                        result += entry.second; replaced = true; break;
                    }
            if (!replaced) result += token;
            previousWord = token;
            for (auto &letter : previousWord) letter = static_cast<char>(std::tolower(static_cast<unsigned char>(letter)));
        } else {
            result += c; ++i;
            if (!std::isspace(static_cast<unsigned char>(c))) previousWord.clear();
        }
    }
    if (depth != 0) throw std::runtime_error("Unbalanced parentheses in CHECK expression.");
    return result;
}
void validate_check_sql(const std::string& expression, const std::vector<std::string>& columns) {
    // Apply the same lexical boundary to persisted and clipboard expressions.
    rewrite_check(expression, {});
    if (expression.find_first_not_of(" \t\r\n") == std::string::npos)
        throw std::runtime_error("Enter a CHECK expression.");
    sqlite3* raw = nullptr;
    const int opened = sqlite3_open(":memory:", &raw);
    std::unique_ptr<sqlite3, decltype(&sqlite3_close)> db(raw, sqlite3_close);
    if (opened != SQLITE_OK) throw std::runtime_error("Cannot create the CHECK syntax validator.");
    sqlite3_db_config(raw, SQLITE_DBCONFIG_DQS_DDL, 0, nullptr);
    sqlite3_db_config(raw, SQLITE_DBCONFIG_DQS_DML, 0, nullptr);
    sqlite3_set_authorizer(raw, [](void*, int action, const char*, const char* function, const char*, const char*) {
        if (action == SQLITE_FUNCTION && !allowed_user_function(function)) return SQLITE_DENY;
        return SQLITE_OK;
    }, nullptr);
    std::string sql = "CREATE TABLE user_check(id INTEGER";
    for (const auto& col : columns) sql += "," + sql_identifier(col) + " ANY";
    sql += ",CHECK(" + expression + ")) STRICT";
    sqlite3_stmt* statement = nullptr;
    const int result = sqlite3_prepare_v2(raw, sql.c_str(), -1, &statement, nullptr);
    std::unique_ptr<sqlite3_stmt, decltype(&sqlite3_finalize)> guard(statement, sqlite3_finalize);
    if (result != SQLITE_OK) throw std::runtime_error(std::string("Invalid CHECK expression: ") + sqlite3_errmsg(raw));
}
}
