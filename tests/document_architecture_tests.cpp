// SPDX-License-Identifier: Apache-2.0
#include "SubCardCore.h"
#include "sqlite3.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>

namespace {
using Doc = std::unique_ptr<SubCardDocument, decltype(&subcard_document_close)>;
using Snapshot = std::unique_ptr<SubCardSnapshot, decltype(&subcard_snapshot_close)>;
Doc owned(SubCardDocument* doc) {
    if (!doc) std::cerr << subcard_last_error() << '\n';
    assert(doc);
    return Doc(doc, subcard_document_close);
}
void state(const Doc& doc, SubCardDataKind kind, SubCardMode mode, bool locked) {
    assert(subcard_document_data_kind(doc.get()) == kind);
    assert(subcard_document_mode(doc.get()) == mode);
    assert(!!subcard_document_schema_is_locked(doc.get()) == locked);
}
void sql(const std::string& path, const char* sql) {
    sqlite3* db = nullptr;
    assert(sqlite3_open(path.c_str(), &db) == SQLITE_OK);
    assert(sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK);
    assert(sqlite3_close(db) == SQLITE_OK);
}
void export_snapshot(const SubCardSnapshot* snapshot, const std::string& path) {
    std::ofstream output(path, std::ios::binary);
    output.write(static_cast<const char*>(subcard_snapshot_bytes(snapshot)), subcard_snapshot_size(snapshot));
    assert(output.good());
}
constexpr const char* schema =
    "CREATE TABLE user_people(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);"
    "CREATE TABLE user_notes(id INTEGER PRIMARY KEY, person INTEGER REFERENCES user_people(id), body TEXT);"
    "CREATE TABLE user_spare(id INTEGER PRIMARY KEY);"
    "CREATE INDEX user_notes_person ON user_notes(person);";
constexpr const char* rows =
    "INSERT INTO user_people VALUES(1,'Éléphant 🚀');"
    "INSERT INTO user_notes VALUES(1,1,'note');";
}

int main(int argc, char** argv) {
    assert(argc == 2);
    const auto root = std::filesystem::u8path(argv[1]);
    std::filesystem::create_directories(root);
    const auto file = (root / "architecture.subcard").u8string();
    const auto copy = (root / "architecture-copy.subcard").u8string();
    const auto legacy = (root / "legacy.subcard").u8string();
    for (const auto& path : {file, copy, legacy}) std::filesystem::remove(path);
    auto doc = owned(subcard_document_new());
    state(doc, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    assert(subcard_document_set_mode(doc.get(), SUBCARD_MODE_USE));
    assert(!subcard_document_is_changed(doc.get()));
    assert(!subcard_document_replace_user_schema(doc.get(), schema));
    assert(subcard_document_set_mode(doc.get(), SUBCARD_MODE_EDIT));
    assert(subcard_document_replace_user_schema(doc.get(), schema));
    assert(subcard_document_is_changed(doc.get()));
    assert(subcard_document_save(doc.get(), file.c_str()));
    assert(!subcard_document_is_changed(doc.get()));
    // There are no user rows, even though system text contains Hello World.
    state(owned(subcard_document_open(file.c_str())), SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);

    // Mixed data, DDL through data commands, and system writes are rejected.
    assert(subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, rows));
    state(doc, SUBCARD_DATA_FAKE, SUBCARD_MODE_EDIT, false);
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_REAL, "INSERT INTO user_people VALUES(2,'real')"));
    // Even a currently empty table belongs to the document's global Fake state.
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_REAL, "INSERT INTO user_spare VALUES(1)"));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_NONE, rows));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, "DROP TABLE user_people"));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, "UPDATE document SET text='bad'"));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, "UPDATE subcard_system_state SET schema_locked=1"));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, "PRAGMA user_version=999"));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, "COMMIT"));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, "ATTACH ':memory:' AS other"));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE,
        "INSERT INTO user_people VALUES(2,'must roll back'); UPDATE document SET text='bad'"));
    assert(subcard_document_set_mode(doc.get(), SUBCARD_MODE_USE));
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, "DELETE FROM user_notes"));
    assert(subcard_document_save(doc.get(), nullptr));
    state(owned(subcard_document_open(file.c_str())), SUBCARD_DATA_FAKE, SUBCARD_MODE_EDIT, false);
    assert(subcard_document_set_mode(doc.get(), SUBCARD_MODE_EDIT));

    // Replacing a fake schema discards rows, but failed replacement rolls back
    // all DDL, fake data deletion, metadata and dirty state.
    for (const char* invalid : {
            "CREATE TABLE user_bad(id); INVALID SQL;",
            "CREATE TABLE document(value);",
            "CREATE VIEW user_view AS SELECT 1;",
            "CREATE VIRTUAL TABLE user_virtual USING fts5(text);",
            "CREATE TABLE user_bad(id); INSERT INTO user_bad VALUES(1);",
            "CREATE TABLE user_bad(id REFERENCES document(id));",
            "CREATE TABLE user_bad(id REFERENCES user_missing(id));",
            "CREATE TABLE user_bad(id); CREATE INDEX user_bad_index ON document(text);",
            "CREATE TABLE user_bad(id); CREATE TRIGGER user_trigger AFTER INSERT ON user_bad BEGIN SELECT 1; END;"}) {
        assert(!subcard_document_replace_user_schema(doc.get(), invalid));
        state(doc, SUBCARD_DATA_FAKE, SUBCARD_MODE_EDIT, false);
        assert(!subcard_document_is_changed(doc.get()));
    }
    assert(subcard_document_set_text(doc.get(), "verify rollback"));
    assert(subcard_document_save(doc.get(), copy.c_str()));
    sql(copy, "CREATE TEMP TABLE verify(ok INTEGER CHECK(ok=1));"
              "INSERT INTO verify SELECT count(*)=1 FROM user_people;"
              "INSERT INTO verify SELECT count(*)=1 FROM user_notes;");
    assert(subcard_document_replace_user_schema(doc.get(), schema));
    state(doc, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    assert(subcard_document_write_user_data(doc.get(), SUBCARD_DATA_FAKE, rows));
    assert(subcard_document_discard_fake_data(doc.get()));
    state(doc, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    assert(!subcard_document_discard_fake_data(doc.get()));
    assert(subcard_document_save(doc.get(), nullptr));

    // Bad relationships roll back without locking an empty schema.
    assert(!subcard_document_write_user_data(doc.get(), SUBCARD_DATA_REAL, "INSERT INTO user_notes VALUES(1,99,'invalid')"));
    state(doc, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    assert(!subcard_document_is_changed(doc.get()));
    assert(subcard_document_write_user_data(doc.get(), SUBCARD_DATA_REAL, rows));
    state(doc, SUBCARD_DATA_REAL, SUBCARD_MODE_EDIT, true);
    assert(!subcard_document_save(doc.get(), (root / "missing-directory" / "file.subcard").u8string().c_str()));
    state(doc, SUBCARD_DATA_REAL, SUBCARD_MODE_EDIT, true);
    assert(subcard_document_is_changed(doc.get()));
    assert(subcard_document_set_mode(doc.get(), SUBCARD_MODE_USE));
    assert(subcard_document_save(doc.get(), file.c_str()));
    auto real = owned(subcard_document_open(file.c_str()));
    state(real, SUBCARD_DATA_REAL, SUBCARD_MODE_USE, true);
    assert(subcard_document_set_mode(real.get(), SUBCARD_MODE_EDIT));
    assert(!subcard_document_is_changed(real.get()));
    assert(!subcard_document_replace_user_schema(real.get(), schema));
    assert(!subcard_document_discard_fake_data(real.get()));
    assert(!subcard_document_write_user_data(real.get(), SUBCARD_DATA_FAKE, "DELETE FROM user_notes"));
    assert(!subcard_document_write_user_data(real.get(), SUBCARD_DATA_FAKE, "INSERT INTO user_spare VALUES(1)"));
    // Editing system-owned design content remains possible with locked schema.
    assert(subcard_document_set_text(real.get(), "design remains editable"));
    assert(subcard_document_write_user_data(real.get(), SUBCARD_DATA_REAL,
        "DELETE FROM user_notes; DELETE FROM user_people;"));
    state(real, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, true);
    assert(!subcard_document_replace_user_schema(real.get(), ""));
    assert(!subcard_document_write_user_data(real.get(), SUBCARD_DATA_FAKE, rows));
    assert(subcard_document_save(real.get(), copy.c_str()));
    state(owned(subcard_document_open(copy.c_str())), SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, true);

    // Snapshot baselines cover schema/data/lock changes, not only text edits.
    auto pending = owned(subcard_document_new());
    assert(subcard_document_replace_user_schema(pending.get(), schema));
    Snapshot snapshot(subcard_document_snapshot(pending.get()), subcard_snapshot_close);
    assert(snapshot);
    assert(subcard_document_write_user_data(pending.get(), SUBCARD_DATA_REAL, rows));
    export_snapshot(snapshot.get(), copy);
    assert(subcard_document_accept_snapshot(pending.get(), snapshot.get(), copy.c_str()));
    assert(subcard_document_is_changed(pending.get()));
    state(pending, SUBCARD_DATA_REAL, SUBCARD_MODE_EDIT, true);
    state(owned(subcard_document_open(copy.c_str())), SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    assert(subcard_document_save(pending.get(), nullptr));
    state(owned(subcard_document_open(copy.c_str())), SUBCARD_DATA_REAL, SUBCARD_MODE_USE, true);
    Snapshot current(subcard_document_snapshot(pending.get()), subcard_snapshot_close);
    export_snapshot(current.get(), copy);
    // Retain a valid real-data fixture for frontend open/mode smoke checks.
    export_snapshot(current.get(), (root / "ui-real.subcard").u8string());
    assert(subcard_document_accept_snapshot(pending.get(), current.get(), copy.c_str()));
    assert(!subcard_document_is_changed(pending.get()));

    auto transient = owned(subcard_document_new());
    assert(subcard_document_replace_user_schema(transient.get(), schema));
    assert(subcard_document_write_user_data(transient.get(), SUBCARD_DATA_REAL,
        "UPDATE user_people SET name='no matching rows'"));
    state(transient, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    assert(subcard_document_write_user_data(transient.get(), SUBCARD_DATA_REAL,
        "INSERT INTO user_people VALUES(1,'brief real record'); DELETE FROM user_people;"));
    state(transient, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, true);
    assert(!subcard_document_replace_user_schema(transient.get(), ""));

    // Original version-1 files have system text and no user schema; opening
    // supplies defaults in memory without rewriting the source file.
    sql(legacy, "PRAGMA application_id=1396851524; PRAGMA user_version=1;"
                "CREATE TABLE document(id INTEGER PRIMARY KEY CHECK(id=1),text TEXT NOT NULL) STRICT;"
                "INSERT INTO document VALUES(1,'legacy');");
    auto old = owned(subcard_document_open(legacy.c_str()));
    state(old, SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    assert(!subcard_document_is_changed(old.get()));
    assert(subcard_document_set_text(old.get(), "new system metadata"));
    assert(subcard_document_save(old.get(), nullptr));
    state(owned(subcard_document_open(legacy.c_str())), SUBCARD_DATA_NONE, SUBCARD_MODE_EDIT, false);
    // Contradictory/tampered state fails closed, rather than unlocking real data.
    sql(file, "PRAGMA ignore_check_constraints=ON; UPDATE subcard_system_state SET schema_locked=0;");
    assert(!subcard_document_open(file.c_str()));
    sql(copy, "UPDATE subcard_system_state SET data_kind=0;");
    assert(!subcard_document_open(copy.c_str()));
    assert(!subcard_document_set_mode(nullptr, SUBCARD_MODE_EDIT));
    assert(!subcard_document_replace_user_schema(nullptr, schema));
    assert(!subcard_document_write_user_data(nullptr, SUBCARD_DATA_REAL, rows));
    std::cout << "Document modes, exclusive data states, schema locks, transactions and snapshots passed.\n";
}
