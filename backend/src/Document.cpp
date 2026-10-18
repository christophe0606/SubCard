// SPDX-License-Identifier: Apache-2.0
#include "SubCardCore.h"
#include "sqlite3.h"
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <atomic>
#include <cstdint>
#include <vector>

namespace {
thread_local std::string last_error;
constexpr int application_id = 0x53424344; // SBCD
std::atomic<std::uint64_t> next_document_id{1};
struct Database {
    sqlite3* handle = nullptr;
    ~Database() { if (handle) sqlite3_close(handle); }
    Database(const Database&) = delete;
    Database& operator=(const Database&) = delete;
    Database() = default;
};
void check(int code, sqlite3* db) {
    if (code != SQLITE_OK && code != SQLITE_DONE && code != SQLITE_ROW)
        throw std::runtime_error(sqlite3_errmsg(db));
}
void open(Database& db, const char* path, int flags) {
    const int result = sqlite3_open_v2(path, &db.handle, flags, nullptr);
    check(result, db.handle);
    sqlite3_busy_timeout(db.handle, 500);
    sqlite3_db_config(db.handle, SQLITE_DBCONFIG_DEFENSIVE, 1, nullptr);
    sqlite3_db_config(db.handle, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, nullptr);
}
bool valid_utf8(const std::string& text) {
    size_t i = 0;
    while (i < text.size()) {
        const auto first = static_cast<unsigned char>(text[i++]);
        if (first < 0x80) continue;
        unsigned value;
        int count;
        unsigned minimum;
        if (first >= 0xc2 && first <= 0xdf) { value = first & 0x1f; count = 1; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { value = first & 0x0f; count = 2; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { value = first & 0x07; count = 3; minimum = 0x10000; }
        else return false;
        while (count--) {
            if (i == text.size()) return false;
            const auto next = static_cast<unsigned char>(text[i++]);
            if ((next & 0xc0) != 0x80) return false;
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}
void exec(sqlite3* db, const char* sql) {
    check(sqlite3_exec(db, sql, nullptr, nullptr, nullptr), db);
}
struct Statement {
    sqlite3_stmt* handle = nullptr;
    Statement(sqlite3* db, const char* sql) {
        check(sqlite3_prepare_v2(db, sql, -1, &handle, nullptr), db);
    }
    ~Statement() { sqlite3_finalize(handle); }
};
int integer(sqlite3* db, const char* sql) {
    Statement stmt(db, sql);
    if (sqlite3_step(stmt.handle) != SQLITE_ROW)
        throw std::runtime_error("Cannot read document format.");
    return sqlite3_column_int(stmt.handle, 0);
}
std::string read_text(sqlite3* db) {
    Statement stmt(db, "SELECT text FROM document WHERE id=1");
    if (sqlite3_step(stmt.handle) != SQLITE_ROW ||
        sqlite3_column_type(stmt.handle, 0) != SQLITE_TEXT)
        throw std::runtime_error("The document content is missing or invalid.");
    const auto* data = sqlite3_column_text(stmt.handle, 0);
    std::string result(reinterpret_cast<const char*>(data), sqlite3_column_bytes(stmt.handle, 0));
    if (result.find('\0') != std::string::npos || !valid_utf8(result))
        throw std::runtime_error("Document text must be UTF-8 without null characters.");
    return result;
}
void validate(sqlite3* db) {
    if (integer(db, "PRAGMA application_id") != application_id)
        throw std::runtime_error("This file is not a SubCard document.");
    if (integer(db, "PRAGMA user_version") != 1)
        throw std::runtime_error("This SubCard document version is not supported.");
    Statement stmt(db, "PRAGMA quick_check");
    if (sqlite3_step(stmt.handle) != SQLITE_ROW ||
        std::string(reinterpret_cast<const char*>(sqlite3_column_text(stmt.handle, 0))) != "ok")
        throw std::runtime_error("The document database is damaged.");
    read_text(db);
}
void backup(sqlite3* destination, sqlite3* source) {
    auto* operation = sqlite3_backup_init(destination, "main", source, "main");
    if (!operation) throw std::runtime_error(sqlite3_errmsg(destination));
    const int result = sqlite3_backup_step(operation, -1);
    const int finished = sqlite3_backup_finish(operation);
    if (result != SQLITE_DONE) throw std::runtime_error(sqlite3_errmsg(destination));
    check(finished, destination);
}
std::string absolute_path(const char* path) {
    if (!path || !*path) throw std::runtime_error("Choose a document file first.");
    return std::filesystem::absolute(std::filesystem::u8path(path)).lexically_normal().u8string();
}
template <typename Result, typename Function>
Result protect(Result failure, Function function) noexcept {
    last_error.clear();
    try { return function(); }
    catch (const std::exception& error) { last_error = error.what(); }
    catch (...) { last_error = "An unexpected document error occurred."; }
    return failure;
}
}

struct SubCardDocument {
    const std::uint64_t id = next_document_id.fetch_add(1);
    Database database;
    std::string text;
    std::string saved_text;
    std::string path;
};

struct SubCardSnapshot {
    std::uint64_t document_id;
    std::string text;
    std::vector<unsigned char> bytes;
};

SubCardDocument* subcard_document_new(void) {
    return protect<SubCardDocument*>(nullptr, [] {
        auto doc = std::make_unique<SubCardDocument>();
        open(doc->database, ":memory:", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
        exec(doc->database.handle,
            "PRAGMA application_id=1396851524; PRAGMA user_version=1;"
            "CREATE TABLE document(id INTEGER PRIMARY KEY CHECK(id=1), text TEXT NOT NULL) STRICT;");
        Statement stmt(doc->database.handle, "INSERT INTO document VALUES(1, ?)");
        check(sqlite3_bind_text(stmt.handle, 1, subcard_greeting(), -1, SQLITE_STATIC), doc->database.handle);
        check(sqlite3_step(stmt.handle), doc->database.handle);
        doc->text = doc->saved_text = subcard_greeting();
        return doc.release();
    });
}
SubCardDocument* subcard_document_open(const char* path) {
    return protect<SubCardDocument*>(nullptr, [=] {
        auto doc = std::make_unique<SubCardDocument>();
        doc->path = absolute_path(path);
        Database source;
        open(source, doc->path.c_str(), SQLITE_OPEN_READONLY);
        validate(source.handle);
        open(doc->database, ":memory:", SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
        backup(doc->database.handle, source.handle);
        doc->text = doc->saved_text = read_text(doc->database.handle);
        return doc.release();
    });
}
void subcard_document_close(SubCardDocument* doc) { delete doc; }
const char* subcard_document_text(const SubCardDocument* doc) { return doc ? doc->text.c_str() : ""; }
const char* subcard_document_path(const SubCardDocument* doc) { return doc ? doc->path.c_str() : ""; }
int subcard_document_is_changed(const SubCardDocument* doc) { return doc && doc->text != doc->saved_text; }
int subcard_document_set_text(SubCardDocument* doc, const char* text) {
    return protect(0, [=] {
        if (!doc || !text) throw std::runtime_error("Invalid document or text.");
        std::string replacement(text);
        if (!valid_utf8(replacement)) throw std::runtime_error("Document text must be valid UTF-8.");
        if (replacement == doc->text) return 1;
        Statement stmt(doc->database.handle, "UPDATE document SET text=? WHERE id=1");
        check(sqlite3_bind_text(stmt.handle, 1, text, -1, SQLITE_TRANSIENT), doc->database.handle);
        check(sqlite3_step(stmt.handle), doc->database.handle);
        doc->text.swap(replacement);
        return 1;
    });
}
int subcard_document_save(SubCardDocument* doc, const char* path) {
    return protect(0, [=] {
        if (!doc) throw std::runtime_error("Invalid document.");
        if (!subcard_document_is_changed(doc)) return 1;
        std::string destination_path = absolute_path(path ? path : doc->path.c_str());
        std::string saved_text = doc->text; // Allocate before committing the file.
        Database destination;
        open(destination, destination_path.c_str(), SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
        // Do not replace an unrelated SQLite database. Native save dialogs handle
        // confirmation before overwriting another SubCard document.
        if (integer(destination.handle, "PRAGMA page_count") > 0) validate(destination.handle);
        exec(destination.handle, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;");
        // SQLite's backup transaction either replaces the whole database or rolls
        // back on failure. Never copy the raw file or forget outstanding WAL data.
        backup(destination.handle, doc->database.handle);
        doc->path.swap(destination_path);
        doc->saved_text.swap(saved_text);
        return 1;
    });
}
const char* subcard_last_error(void) { return last_error.c_str(); }
const char* subcard_sqlite_version(void) { return sqlite3_libversion(); }

SubCardSnapshot* subcard_document_snapshot(const SubCardDocument* doc) {
    return protect<SubCardSnapshot*>(nullptr, [=] {
        if (!doc) throw std::runtime_error("Invalid document.");
        auto snapshot = std::make_unique<SubCardSnapshot>();
        snapshot->document_id = doc->id;
        snapshot->text = doc->text;
        sqlite3_int64 size = 0;
        std::unique_ptr<unsigned char, decltype(&sqlite3_free)> bytes(
            sqlite3_serialize(doc->database.handle, "main", &size, 0), sqlite3_free);
        if (!bytes || size <= 0) throw std::runtime_error("Cannot create a document snapshot.");
        snapshot->bytes.assign(bytes.get(), bytes.get() + size);
        return snapshot.release();
    });
}
const void* subcard_snapshot_bytes(const SubCardSnapshot* snapshot) {
    return snapshot ? snapshot->bytes.data() : nullptr;
}
size_t subcard_snapshot_size(const SubCardSnapshot* snapshot) {
    return snapshot ? snapshot->bytes.size() : 0;
}
void subcard_snapshot_close(SubCardSnapshot* snapshot) { delete snapshot; }
int subcard_document_accept_snapshot(SubCardDocument* doc, const SubCardSnapshot* snapshot, const char* path) {
    return protect(0, [=] {
        if (!doc || !snapshot || snapshot->document_id != doc->id)
            throw std::runtime_error("The saved snapshot belongs to another document.");
        auto destination = absolute_path(path);
        auto baseline = snapshot->text;
        doc->path.swap(destination);
        doc->saved_text.swap(baseline);
        return 1;
    });
}
