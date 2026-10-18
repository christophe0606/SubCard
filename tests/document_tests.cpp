// SPDX-License-Identifier: Apache-2.0
#include "SubCardCore.h"
#include "sqlite3.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>

using Doc = std::unique_ptr<SubCardDocument, decltype(&subcard_document_close)>;
Doc owned(SubCardDocument* pointer) { assert(pointer); return Doc(pointer, subcard_document_close); }
std::string text(const Doc& doc) { return subcard_document_text(doc.get()); }
std::string contents(const std::filesystem::path& path) {
    std::ifstream stream(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(stream), {}};
}
void sql(const std::string& path, const char* statement) {
    sqlite3* db = nullptr;
    assert(sqlite3_open(path.c_str(), &db) == SQLITE_OK);
    assert(sqlite3_exec(db, statement, nullptr, nullptr, nullptr) == SQLITE_OK);
    assert(sqlite3_close(db) == SQLITE_OK);
}

int main(int argc, char** argv) {
    assert(argc == 2);
    const auto root = std::filesystem::u8path(argv[1]);
    std::filesystem::create_directories(root);
    const auto first = (root / "first.subcard").u8string();
    const auto second = (root / "copie-étoile.subcard").u8string();
    const auto invalid = (root / "unrelated.sqlite").u8string();
    const auto future = (root / "future.subcard").u8string();
    for (const auto& path : {first, second, invalid, future}) std::filesystem::remove(std::filesystem::u8path(path));

    assert(std::string(subcard_sqlite_version()) == "3.54.1");
    auto doc = owned(subcard_document_new());
    assert(text(doc) == "Hello World");
    assert(!subcard_document_is_changed(doc.get()));
    assert(subcard_document_save(doc.get(), first.c_str()));
    assert(!std::filesystem::exists(first)); // Clean Save As is a no-op.
    assert(subcard_document_set_text(doc.get(), "Hello World"));
    assert(!subcard_document_is_changed(doc.get()));
    assert(subcard_document_set_text(doc.get(), "new text"));
    assert(subcard_document_is_changed(doc.get()));
    assert(subcard_document_set_text(doc.get(), "Hello World"));
    assert(!subcard_document_is_changed(doc.get())); // Returning to saved content is clean.

    const std::string unicode = "Sub-espace — résumé 🚀\nQuote ' and \" and SQL ; DROP TABLE document;";
    assert(subcard_document_set_text(doc.get(), unicode.c_str()));
    assert(!subcard_document_save(doc.get(), nullptr)); // Untitled must choose a path.
    assert(subcard_document_is_changed(doc.get()));
    assert(subcard_document_save(doc.get(), first.c_str()));
    assert(!subcard_document_is_changed(doc.get()));
    assert(contents(first).substr(0,16) == std::string("SQLite format 3\0",16));
    const auto original = contents(first);
    auto reopened = owned(subcard_document_open(first.c_str()));
    assert(text(reopened) == unicode);
    assert(!subcard_document_is_changed(reopened.get()));
    assert(subcard_document_set_text(reopened.get(), "unsaved edit"));
    assert(contents(first) == original); // Editing never silently writes the saved file.

    const auto missing = (root / "missing-directory" / "file.subcard").u8string();
    assert(!subcard_document_save(reopened.get(), missing.c_str()));
    assert(subcard_document_is_changed(reopened.get()));
    assert(std::string(subcard_document_path(reopened.get())) == first);
    assert(text(reopened) == "unsaved edit");
    assert(contents(first) == original);

    sql(invalid, "CREATE TABLE unrelated(value); INSERT INTO unrelated VALUES('keep me');");
    const auto unrelated = contents(invalid);
    assert(!subcard_document_open(invalid.c_str()));
    assert(!subcard_document_save(reopened.get(), invalid.c_str()));
    assert(contents(invalid) == unrelated);
    assert(subcard_document_is_changed(reopened.get()));
    assert(!subcard_document_open(missing.c_str()));

    assert(subcard_document_save(reopened.get(), second.c_str()));
    assert(!subcard_document_is_changed(reopened.get()));
    assert(contents(first) == original); // Save As leaves the source unchanged.
    assert(text(owned(subcard_document_open(second.c_str()))) == "unsaved edit");
    assert(subcard_document_set_text(reopened.get(), "saved to the same file"));
    assert(subcard_document_save(reopened.get(), nullptr));
    assert(text(owned(subcard_document_open(second.c_str()))) == "saved to the same file");

    // Unknown future tables, metadata and binary resources survive Open + Save As.
    sql(first, "CREATE TABLE resources(id INTEGER PRIMARY KEY, bytes BLOB);"
               "INSERT INTO resources VALUES(1, X'00010200FF');");
    auto with_resources = owned(subcard_document_open(first.c_str()));
    assert(subcard_document_set_text(with_resources.get(), "preserve everything"));
    assert(subcard_document_save(with_resources.get(), second.c_str()));
    sql(second, "CREATE TEMP TABLE verify(value INTEGER CHECK(value=1));"
                "INSERT INTO verify SELECT hex(bytes)='00010200FF' FROM resources WHERE id=1;");

    // iOS Files writes an immutable full-database snapshot. Canceling the picker
    // must leave the original document changed and retain its original path.
    assert(subcard_document_set_text(with_resources.get(), "iPhone snapshot — 🚀"));
    using Snapshot = std::unique_ptr<SubCardSnapshot, decltype(&subcard_snapshot_close)>;
    {
        Snapshot canceled(subcard_document_snapshot(with_resources.get()), subcard_snapshot_close);
        assert(canceled && subcard_snapshot_size(canceled.get()) > 0);
    }
    assert(subcard_document_is_changed(with_resources.get()));
    assert(std::string(subcard_document_path(with_resources.get())) == second);
    Snapshot snapshot(subcard_document_snapshot(with_resources.get()), subcard_snapshot_close);
    assert(snapshot);
    const auto exported = (root / "iphone-export.subcard").u8string();
    {
        std::ofstream out(exported, std::ios::binary);
        out.write(static_cast<const char*>(subcard_snapshot_bytes(snapshot.get())),
                  static_cast<std::streamsize>(subcard_snapshot_size(snapshot.get())));
        assert(out.good());
    }
    assert(text(owned(subcard_document_open(exported.c_str()))) == "iPhone snapshot — 🚀");
    sql(exported, "CREATE TEMP TABLE verify(value INTEGER CHECK(value=1));"
                  "INSERT INTO verify SELECT hex(bytes)='00010200FF' FROM resources WHERE id=1;");
    // A native file writer may complete after another edit; that edit stays dirty.
    assert(subcard_document_set_text(with_resources.get(), "edited after snapshot"));
    assert(subcard_document_accept_snapshot(with_resources.get(), snapshot.get(), exported.c_str()));
    assert(subcard_document_is_changed(with_resources.get()));
    assert(std::string(subcard_document_path(with_resources.get())) == exported);
    assert(subcard_document_set_text(with_resources.get(), "iPhone snapshot — 🚀"));
    assert(!subcard_document_is_changed(with_resources.get()));
    assert(!subcard_document_accept_snapshot(doc.get(), snapshot.get(), exported.c_str()));
    assert(!subcard_document_accept_snapshot(with_resources.get(), snapshot.get(), ""));
    assert(std::string(subcard_document_path(with_resources.get())) == exported);
    std::filesystem::copy_file(first, future);
    sql(future, "PRAGMA user_version=999;");
    assert(!subcard_document_open(future.c_str()));
    assert(!subcard_document_set_text(doc.get(), "\xC0\xAF"));
    sql(future, "PRAGMA user_version=1; UPDATE document SET text=CAST(X'EDA080' AS TEXT);");
    assert(!subcard_document_open(future.c_str()));
    std::ofstream(root / "not-a-database.subcard") << "This is not a database";
    assert(!subcard_document_open((root / "not-a-database.subcard").u8string().c_str()));

    assert(!std::filesystem::exists(first + "-wal"));
    assert(!std::filesystem::exists(second + "-journal"));
    std::cout << "Document persistence, dirty state, Unicode, failure safety, and full-database copying passed (SQLite "
              << subcard_sqlite_version() << ").\n";
}
