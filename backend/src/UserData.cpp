// SPDX-License-Identifier: Apache-2.0
#include "UserData.h"
#include "sqlite3.h"
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace subcard {
namespace {
void check(int result, sqlite3* db) {
    if (result != SQLITE_OK && result != SQLITE_ROW && result != SQLITE_DONE)
        throw std::runtime_error(sqlite3_errmsg(db));
}
void exec(sqlite3* db, const char* sql) { check(sqlite3_exec(db, sql, nullptr, nullptr, nullptr), db); }
struct Statement {
    sqlite3_stmt* value = nullptr;
    Statement(sqlite3* db, const char* sql) { check(sqlite3_prepare_v2(db, sql, -1, &value, nullptr), db); }
    ~Statement() { sqlite3_finalize(value); }
};
int scalar(sqlite3* db, const char* sql) {
    Statement stmt(db, sql);
    if (sqlite3_step(stmt.value) != SQLITE_ROW) throw std::runtime_error("Invalid document state.");
    return sqlite3_column_int(stmt.value, 0);
}
std::vector<std::string> tables(sqlite3* db) {
    Statement stmt(db, "SELECT name FROM sqlite_schema WHERE type='table' AND substr(name,1,5)='user_' ORDER BY name");
    std::vector<std::string> result;
    int step;
    while ((step = sqlite3_step(stmt.value)) == SQLITE_ROW)
        result.emplace_back(reinterpret_cast<const char*>(sqlite3_column_text(stmt.value, 0)));
    check(step, db);
    return result;
}
std::string quote(const std::string& identifier) {
    std::string result = "\"";
    for (char c : identifier) { result += c; if (c == '"') result += c; }
    return result + "\"";
}
bool has_rows(sqlite3* db) {
    for (const auto& table : tables(db))
        if (scalar(db, ("SELECT EXISTS(SELECT 1 FROM " + quote(table) + " LIMIT 1)").c_str())) return true;
    return false;
}
void require_edit(SubCardMode mode) {
    if (mode != SUBCARD_MODE_EDIT) throw std::runtime_error("Return to editing mode first.");
}
void require_unlocked(DocumentState state) {
    if (state.schema_locked) throw std::runtime_error("The user schema is locked because this document has held real data.");
}
struct Transaction {
    sqlite3* db;
    bool committed = false;
    explicit Transaction(sqlite3* db) : db(db) {
        exec(db, "BEGIN IMMEDIATE; PRAGMA defer_foreign_keys=ON;");
    }
    ~Transaction() { if (!committed) sqlite3_exec(db, "ROLLBACK", nullptr, nullptr, nullptr); }
    void commit() { exec(db, "COMMIT"); committed = true; }
};
bool user_name(const char* name) { return name && std::strncmp(name, "user_", 5) == 0; }
bool user_index_name(const char* name) {
    return user_name(name) || (name && std::strncmp(name, "sqlite_autoindex_user_", 22) == 0);
}
void validate_user_relationships(sqlite3* db) {
    const auto user_tables = tables(db);
    for (const auto& table : user_tables) {
        Statement stmt(db, ("PRAGMA foreign_key_list(" + quote(table) + ")").c_str());
        int step;
        while ((step = sqlite3_step(stmt.value)) == SQLITE_ROW) {
            const auto* parent = reinterpret_cast<const char*>(sqlite3_column_text(stmt.value, 2));
            if (!user_name(parent) || std::find(user_tables.begin(), user_tables.end(), parent) == user_tables.end())
                throw std::runtime_error("User relationships must reference existing user tables.");
        }
        check(step, db);
    }
}
// SQL is an internal storage boundary for future typed schema/data commands.
// No system writes, transactions, PRAGMAs, extensions, views, virtual tables,
// triggers, or attached databases can be smuggled through these batches.
int authorize(void* context, int action, const char* first, const char* second,
              const char* database, const char* source) {
    const bool schema = *static_cast<bool*>(context);
    if (source || (database && std::strcmp(database, "main") != 0)) return SQLITE_DENY;
    switch (action) {
    case SQLITE_CREATE_TABLE: return schema && user_name(first) ? SQLITE_OK : SQLITE_DENY;
    case SQLITE_CREATE_INDEX: return schema && user_name(second) && user_index_name(first) ? SQLITE_OK : SQLITE_DENY;
    case SQLITE_REINDEX: return schema && user_index_name(first) ? SQLITE_OK : SQLITE_DENY;
    case SQLITE_INSERT: case SQLITE_UPDATE: case SQLITE_DELETE:
        return (schema ? first && std::strcmp(first, "sqlite_master") == 0 : user_name(first)) ? SQLITE_OK : SQLITE_DENY;
    case SQLITE_READ:
        return user_name(first) || (schema && first && std::strcmp(first, "sqlite_master") == 0) ? SQLITE_OK : SQLITE_DENY;
    case SQLITE_SELECT: case SQLITE_RECURSIVE: return SQLITE_OK;
    case SQLITE_FUNCTION:
        for (const char* name : {"abs", "coalesce", "ifnull", "length", "lower", "upper", "min", "max", "count", "sum"})
            if (second && sqlite3_stricmp(name, second) == 0) return SQLITE_OK;
        return SQLITE_DENY;
    default: return SQLITE_DENY;
    }
}
void restricted_exec(sqlite3* db, const char* sql, bool schema) {
    if (!sql) throw std::runtime_error("Invalid user SQL batch.");
    struct Authorization {
        sqlite3* db;
        ~Authorization() { sqlite3_set_authorizer(db, nullptr, nullptr); }
    } guard{db};
    check(sqlite3_set_authorizer(db, authorize, &schema), db);
    exec(db, sql);
}
void store_state(sqlite3* db, DocumentState state) {
    Statement stmt(db, "UPDATE subcard_system_state SET data_kind=?, schema_locked=? WHERE id=1");
    check(sqlite3_bind_int(stmt.value, 1, state.data_kind), db);
    check(sqlite3_bind_int(stmt.value, 2, state.schema_locked), db);
    check(sqlite3_step(stmt.value), db);
}
void clear_rows(sqlite3* db) {
    for (const auto& table : tables(db)) exec(db, ("DELETE FROM " + quote(table)).c_str());
}
}

void initialize_document_state(sqlite3* db) {
    exec(db, "CREATE TABLE IF NOT EXISTS subcard_system_state("
             "id INTEGER PRIMARY KEY CHECK(id=1),"
             "data_kind INTEGER NOT NULL CHECK(data_kind BETWEEN 0 AND 2),"
             "schema_locked INTEGER NOT NULL CHECK(schema_locked IN (0,1)),"
             "CHECK(data_kind!=1 OR schema_locked=0), CHECK(data_kind!=2 OR schema_locked=1)) STRICT;"
             "INSERT OR IGNORE INTO subcard_system_state VALUES(1,0,0);");
}
DocumentState read_document_state(sqlite3* db) {
    const bool metadata = scalar(db, "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='subcard_system_state' AND type='table')");
    if (!metadata) {
        if (!tables(db).empty()) throw std::runtime_error("User tables require document state metadata.");
        return {}; // Original version-1 greeting-only documents have no user data.
    }
    Statement stmt(db, "SELECT data_kind, schema_locked FROM subcard_system_state WHERE id=1");
    if (sqlite3_step(stmt.value) != SQLITE_ROW || sqlite3_column_type(stmt.value, 0) != SQLITE_INTEGER ||
        sqlite3_column_type(stmt.value, 1) != SQLITE_INTEGER ||
        scalar(db, "SELECT count(*) FROM subcard_system_state") != 1)
        throw std::runtime_error("Invalid document state metadata.");
    const auto kind = sqlite3_column_int64(stmt.value, 0), locked = sqlite3_column_int64(stmt.value, 1);
    if (kind < 0 || kind > 2 || (locked != 0 && locked != 1) ||
        (kind == SUBCARD_DATA_FAKE && locked) || (kind == SUBCARD_DATA_REAL && !locked) ||
        (has_rows(db) != (kind != SUBCARD_DATA_NONE)))
        throw std::runtime_error("User data and document state are inconsistent.");
    // The first storage implementation deliberately supports ordinary tables
    // and indexes only. Reject unsupported executable schema on open as well.
    if (scalar(db, "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE "
                   "(type IN ('trigger','view') AND (substr(name,1,5)='user_' OR substr(tbl_name,1,5)='user_')) "
                   "OR (type='table' AND substr(name,1,5)='user_' AND upper(sql) LIKE 'CREATE VIRTUAL%'))"))
        throw std::runtime_error("Unsupported user schema objects.");
    validate_user_relationships(db);
    Statement foreign_keys(db, "PRAGMA foreign_key_check");
    if (sqlite3_step(foreign_keys.value) != SQLITE_DONE) throw std::runtime_error("The document contains invalid relationships.");
    return {static_cast<SubCardDataKind>(kind), locked != 0};
}
DocumentState replace_user_schema(sqlite3* db, DocumentState state, SubCardMode mode, const char* sql) {
    require_edit(mode);
    require_unlocked(state);
    Transaction transaction(db);
    clear_rows(db);
    for (const auto& table : tables(db)) exec(db, ("DROP TABLE " + quote(table)).c_str());
    restricted_exec(db, sql, true);
    validate_user_relationships(db);
    if (has_rows(db)) throw std::runtime_error("A schema definition cannot insert user data.");
    state.data_kind = SUBCARD_DATA_NONE;
    store_state(db, state);
    transaction.commit();
    return state;
}
DocumentState write_user_data(sqlite3* db, DocumentState state, SubCardMode mode,
                              SubCardDataKind kind, const char* sql) {
    if (kind != SUBCARD_DATA_FAKE && kind != SUBCARD_DATA_REAL) throw std::runtime_error("Choose fake or real user data.");
    if (kind == SUBCARD_DATA_FAKE) { require_edit(mode); require_unlocked(state); }
    if (state.data_kind != SUBCARD_DATA_NONE && state.data_kind != kind)
        throw std::runtime_error("Fake and real data cannot be mixed. Discard fake data before entering real data.");
    Transaction transaction(db);
    const auto before = sqlite3_total_changes64(db);
    restricted_exec(db, sql, false);
    state.data_kind = has_rows(db) ? kind : SUBCARD_DATA_NONE;
    // Even real rows inserted and deleted in one successful batch lock schema.
    if (kind == SUBCARD_DATA_REAL && sqlite3_total_changes64(db) != before) state.schema_locked = true;
    store_state(db, state);
    transaction.commit();
    return state;
}
DocumentState discard_fake_data(sqlite3* db, DocumentState state, SubCardMode mode) {
    require_edit(mode);
    require_unlocked(state);
    if (state.data_kind != SUBCARD_DATA_FAKE) throw std::runtime_error("This document has no fake data to discard.");
    Transaction transaction(db);
    clear_rows(db);
    state.data_kind = SUBCARD_DATA_NONE;
    store_state(db, state);
    transaction.commit();
    return state;
}
}
