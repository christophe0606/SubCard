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
Doc own(SubCardDocument *p) {
    if (!p)
        std::cerr << subcard_last_error() << '\n';
    assert(p);
    return {p, subcard_document_close};
}
std::string graph(const Doc &d) {
    const char *s = subcard_document_er_json(d.get());
    assert(s);
    return s;
}
void cmd(const Doc &d, const std::string &s) {
    if (!subcard_document_er_command(d.get(), s.c_str())) {
        std::cerr << s << ": " << subcard_last_error() << '\n';
        std::abort();
    }
}
void fail(const Doc &d, const std::string &s) {
    auto before = graph(d);
    assert(!subcard_document_er_command(d.get(), s.c_str()));
    assert(graph(d) == before);
}
void write(const Doc &d, const char *s, SubCardDataKind kind = SUBCARD_DATA_FAKE) {
    if (!subcard_document_write_user_data(d.get(), kind, s)) {
        std::cerr << s << ": " << subcard_last_error() << '\n';
        std::abort();
    }
}
std::string scalar(const std::string &file, const char *sql) {
    sqlite3 *db = nullptr;
    assert(sqlite3_open(file.c_str(), &db) == SQLITE_OK);
    sqlite3_stmt *q = nullptr;
    assert(sqlite3_prepare_v2(db, sql, -1, &q, nullptr) == SQLITE_OK);
    assert(sqlite3_step(q) == SQLITE_ROW);
    const char *p = reinterpret_cast<const char *>(sqlite3_column_text(q, 0));
    std::string s = p ? p : "";
    sqlite3_finalize(q);
    sqlite3_close(db);
    return s;
}
void sql(const std::string &file, const char *sql) {
    sqlite3 *db = nullptr;
    assert(sqlite3_open(file.c_str(), &db) == SQLITE_OK);
    assert(sqlite3_exec(db, sql, nullptr, nullptr, nullptr) == SQLITE_OK);
    sqlite3_close(db);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    std::filesystem::create_directories(argv[1]);
    auto file = (std::filesystem::path(argv[1]) / "er.subcard").string();
    std::filesystem::remove(file);
    auto d = own(subcard_document_new());
    assert(!subcard_document_is_changed(d.get()));
    // Unbound foreign keys, unique/nonunique indexes, and destination constraints.
    auto indexes = own(subcard_document_new());
    cmd(indexes, R"({"op":"add_table","name":"Products","x":10,"y":10})"); // 1
    cmd(indexes, R"({"op":"add_index","table":1,"name":"sku","kind":"index","unique":false})"); // 2
    cmd(indexes, R"({"op":"add_index","table":1,"name":"related","kind":"secondary"})"); // 3, unconnected
    assert(graph(indexes).find("\"edges\":[]") != std::string::npos);
    fail(indexes, R"({"op":"connect","table":1,"field":3,"target":1,"targetField":2})");
    const auto indexFile = (std::filesystem::path(argv[1]) / "indexes.subcard").string();
    assert(subcard_document_save(indexes.get(), indexFile.c_str()));
    assert(scalar(indexFile, "SELECT sql FROM sqlite_schema WHERE name='user_t1'").find("f2 INTEGER UNIQUE") == std::string::npos);
    assert(scalar(indexFile, "SELECT count(*) FROM sqlite_schema WHERE name='user_i2'") == "1");
    cmd(indexes, R"({"op":"update_index","table":1,"id":2,"name":"sku","unique":true})");
    cmd(indexes, R"({"op":"connect","table":1,"field":3,"target":1,"targetField":2})");
    fail(indexes, R"({"op":"update_index","table":1,"id":2,"name":"sku","unique":false})");
    cmd(indexes, R"({"op":"delete_connection","id":4})");
    cmd(indexes, R"({"op":"update_index","table":1,"id":2,"name":"sku","unique":false})");
    cmd(indexes, R"({"op":"undo"})");
    assert(subcard_document_save(indexes.get(), indexFile.c_str()));
    assert(scalar(indexFile, "SELECT sql FROM sqlite_schema WHERE name='user_t1'").find("f2 INTEGER UNIQUE") != std::string::npos);
    auto reopenedIndexes = own(subcard_document_open(indexFile.c_str()));
    assert(graph(reopenedIndexes).find("\"unique\":true") != std::string::npos);
    cmd(indexes, R"({"op":"redo"})");
    assert(subcard_document_save(indexes.get(), indexFile.c_str()));
    auto nonuniqueIndexes = own(subcard_document_open(indexFile.c_str()));
    assert(graph(nonuniqueIndexes).find("\"unique\":false") != std::string::npos);
    write(nonuniqueIndexes, "INSERT INTO user_t1(f2) VALUES(42),(42)");
    assert(subcard_document_discard_fake_data(nonuniqueIndexes.get()));
    cmd(nonuniqueIndexes, R"({"op":"update_index","table":1,"id":2,"name":"sku","unique":true})");
    assert(!subcard_document_write_user_data(nonuniqueIndexes.get(), SUBCARD_DATA_FAKE,
                                           "INSERT INTO user_t1(f2) VALUES(42),(42)"));
    assert(subcard_document_data_kind(nonuniqueIndexes.get()) == SUBCARD_DATA_NONE);
    const auto oldIndexFile = (std::filesystem::path(argv[1]) / "legacy-index.subcard").string();
    assert(subcard_document_save(nonuniqueIndexes.get(), oldIndexFile.c_str()));
    sql(oldIndexFile, "UPDATE subcard_system_er_model SET json=json_remove(json,'$.tables[0].fields[0].unique','$.tables[0].fields[1].unique')");
    auto legacyIndexes = own(subcard_document_open(oldIndexFile.c_str()));
    assert(graph(legacyIndexes).find("\"unique\":true") != std::string::npos);
    // Anchored zoom-out requires negative pan and can exceed one million world units.
    auto navigation = own(subcard_document_new());
    cmd(navigation, R"({"op":"view","zoom":0.0001,"panX":-3200000,"panY":-450,"calibration":1})");
    const auto navigationFile = (std::filesystem::path(argv[1]) / "navigation.subcard").string();
    assert(subcard_document_save(navigation.get(), navigationFile.c_str()));
    auto camera = own(subcard_document_open(navigationFile.c_str()));
    assert(graph(camera).find("-3200000.000000") != std::string::npos);
    assert(graph(camera).find("\"canUndo\":false") != std::string::npos);
    fail(camera, R"({"op":"view","zoom":1,"panX":-1e10,"panY":0,"calibration":1})");
    fail(d, "{}");
    fail(d, R"({"op":"add_table","name":"bad\u0000name","x":1,"y":1})");
    fail(d, R"({"op":"add_table","name":"Huge","x":1e300,"y":1})");
    fail(d, "not JSON");
    fail(d, "{\"op\":\"add_table\",\"name\":\"\",\"x\":1,\"y\":1}");
    cmd(d, R"({"op":"add_table","name":"People 🚀","x":60,"y":60})");             // table 1
    cmd(d, R"({"op":"add_table","name":"Notes","x":600,"y":120})");               // table 2
    cmd(d, R"({"op":"add_index","table":1,"name":"code","kind":"index"})");       // field 3
    cmd(d, R"({"op":"add_index","table":2,"name":"person","kind":"secondary"})"); // field 4
    cmd(d, R"({"op":"connect","table":2,"field":4,"target":1,"targetField":0})"); // edge 5

    cmd(d, R"({"op":"connect","table":2,"field":4,"target":1,"targetField":3})");
    assert(graph(d).find("\"targetField\":3") != std::string::npos);
    assert(graph(d).find("\"id\":5,\"table\":2") != std::string::npos);
    cmd(d, R"({"op":"undo"})"); // Retarget restores the same arrow and its former primary-key destination.
    assert(graph(d).find("\"targetField\":0") != std::string::npos);
    fail(d, R"({"op":"connect","table":1,"field":3,"target":2,"targetField":0})");
    fail(d, R"({"op":"delete_table","id":99})");
    fail(d, R"({"op":"add_index","table":1,"name":"ID","kind":"index"})");
    fail(d, R"({"op":"add_table","name":"notes","x":0,"y":0})");
    fail(d, R"({"op":"move_table","id":1,"x":-1,"y":1})");
    fail(d, R"({"op":"view","zoom":0,"panX":0,"panY":0,"calibration":1})");
    cmd(d, R"({"op":"move_table","id":1,"x":90.5,"y":100.25})");
    cmd(d, R"({"op":"undo"})");
    assert(graph(d).find("90.500000") == std::string::npos);
    cmd(d, R"({"op":"view","zoom":0.5,"panX":75,"panY":20,"calibration":1.2})"); // leaves redo intact
    assert(graph(d).find("\"canRedo\":true") != std::string::npos);
    cmd(d, R"({"op":"redo"})");
    assert(graph(d).find("90.500000") != std::string::npos);
    cmd(d, R"({"op":"update_table","id":1,"name":"People 🚀","color":"#7651A8"})");
    assert(subcard_document_save(d.get(), file.c_str()));
    assert(!subcard_document_is_changed(d.get()));
    const auto demo = (std::filesystem::path(argv[1]) / "demo.subcard").string();
    std::filesystem::copy_file(file, demo, std::filesystem::copy_options::overwrite_existing);
    assert(scalar(file, "SELECT json_type(json,'$.tables[0].id') FROM subcard_system_er_model") == "integer");
    // A metadata write failure must roll back generated DDL and history as well.
    const auto atomic = (std::filesystem::path(argv[1]) / "atomic.subcard").string();
    std::filesystem::copy_file(file, atomic, std::filesystem::copy_options::overwrite_existing);
    sql(atomic, "CREATE TRIGGER fail_er BEFORE UPDATE ON subcard_system_er_model BEGIN SELECT "
                "RAISE(ABORT,'metadata write failed'); END");
    auto rejected = own(subcard_document_open(atomic.c_str()));
    fail(rejected, R"({"op":"delete_table","id":1})");
    assert(!subcard_document_is_changed(rejected.get()));
    auto bytes = subcard_document_snapshot(rejected.get());
    assert(bytes);
    const auto rolled = (std::filesystem::path(argv[1]) / "rolled.subcard").string();
    {
        std::ofstream out(rolled, std::ios::binary);
        out.write(static_cast<const char *>(subcard_snapshot_bytes(bytes)), subcard_snapshot_size(bytes));
        assert(out.good());
    }
    subcard_snapshot_close(bytes);
    assert(scalar(rolled, "SELECT count(*) FROM sqlite_schema WHERE name='user_t1'") == "1");
    auto reopened = own(subcard_document_open(file.c_str()));
    auto restored = graph(reopened);
    cmd(reopened, R"({"op":"move_table","id":1,"x":100,"y":100})");
    assert(subcard_document_is_changed(reopened.get()));
    cmd(reopened, R"({"op":"undo"})");
    assert(!subcard_document_is_changed(reopened.get()));
    cmd(reopened, R"({"op":"view","zoom":1,"panX":0,"panY":0,"calibration":1})");
    assert(subcard_document_is_changed(reopened.get()));
    assert(restored.find("#7651A8") != std::string::npos && restored.find("0.500000") != std::string::npos &&
           restored.find("90.500000") != std::string::npos);
    assert(restored.find("\"canUndo\":false") != std::string::npos);
    assert(scalar(file, "SELECT count(*) FROM sqlite_schema WHERE name IN "
                        "('subcard_system_er_model','subcard_system_er_view')") == "2");
    assert(scalar(file, "SELECT sql FROM sqlite_schema WHERE name='user_t1'").find("AUTOINCREMENT") !=
           std::string::npos);
    assert(scalar(file, "SELECT [on_delete] FROM pragma_foreign_key_list('user_t2')") == "RESTRICT");
    // Fake data survives cosmetic commands and failed structural commands.
    write(d, "INSERT INTO user_t1(f3) VALUES(10); INSERT INTO user_t2(f4) VALUES(1); INSERT INTO user_t2(f4) "
             "VALUES(1);");
    assert(!subcard_document_write_user_data(d.get(), SUBCARD_DATA_FAKE, "DELETE FROM user_t1 WHERE id=1"));
    fail(d, R"({"op":"delete_index","table":1,"id":3})");
    cmd(d, R"({"op":"update_index","table":1,"id":3,"name":"renamed_code"})");
    cmd(d, R"({"op":"undo"})"); // label undo must not rebuild tables or discard fake rows
    assert(!subcard_document_replace_user_schema(d.get(), ""));
    cmd(d, R"({"op":"move_table","id":2,"x":650,"y":150})");
    cmd(d, R"({"op":"undo"})");
    assert(subcard_document_discard_fake_data(d.get()));
    cmd(d, R"({"op":"update_connection","id":5,"many":false,"cascade":false})");
    write(d, "INSERT INTO user_t1(f3) VALUES(10); INSERT INTO user_t2(f4) VALUES(1);");
    assert(
        !subcard_document_write_user_data(d.get(), SUBCARD_DATA_FAKE, "INSERT INTO user_t2(f4) VALUES(1)"));
    assert(subcard_document_discard_fake_data(d.get()));
    cmd(d, R"({"op":"update_connection","id":5,"many":true,"cascade":true})");
    write(d, "INSERT INTO user_t1(f3) VALUES(10); INSERT INTO user_t2(f4) VALUES(1); DELETE FROM user_t1 "
             "WHERE id=1;");
    assert(subcard_document_data_kind(d.get()) == SUBCARD_DATA_NONE); // cascade removed all rows
    cmd(d, R"({"op":"delete_connection","id":5})");
    cmd(d, R"({"op":"connect","table":2,"field":4,"target":1,"targetField":3})"); // edge 6 to index
    write(d, "INSERT INTO user_t1(f3) VALUES(10); INSERT INTO user_t2(f4) VALUES(10);");
    assert(
        !subcard_document_write_user_data(d.get(), SUBCARD_DATA_FAKE, "INSERT INTO user_t2(f4) VALUES(999)"));
    assert(subcard_document_discard_fake_data(d.get()));
    cmd(d, R"({"op":"delete_table","id":1})");
    assert(graph(d).find("\"edges\":[]") != std::string::npos);
    cmd(d, R"({"op":"undo"})");
    assert(graph(d).find("People 🚀") != std::string::npos);
    assert(graph(d).find("\"targetField\":3") != std::string::npos);
    cmd(d,
        R"({"op":"paste_table","table":{"id":1,"name":"People 🚀","color":"#7651A8","x":90,"y":100,"fields":[{"id":3,"name":"code","kind":"index"}]}})");
    assert(graph(d).find("People 🚀 copy") != std::string::npos);
    cmd(d, R"({"op":"undo"})");
    cmd(d, R"({"op":"update_index","table":1,"id":3,"name":"external_code"})");
    assert(graph(d).find("\"canRedo\":false") != std::string::npos);
    fail(d, R"({"op":"update_table","id":1,"name":"Notes","color":"#000000"})");
    fail(d, R"({"op":"update_table","id":1,"name":"People","color":"red"})");
    // Real writes invalidate history permanently; layout/color remain editable.
    write(d, "INSERT INTO user_t1(f3) VALUES(10);", SUBCARD_DATA_REAL);
    assert(subcard_document_schema_is_locked(d.get()));
    fail(d, R"({"op":"undo"})");
    fail(d, R"({"op":"add_table","name":"Locked","x":0,"y":0})");
    fail(d, R"({"op":"update_index","table":1,"id":3,"name":"Changed"})");
    fail(d, R"({"op":"update_table","id":1,"name":"Changed","color":"#7651A8"})");
    cmd(d, R"({"op":"move_table","id":1,"x":300,"y":250})");
    cmd(d, R"({"op":"undo"})");
    cmd(d, R"({"op":"redo"})");
    assert(subcard_document_set_mode(d.get(), SUBCARD_MODE_USE));
    fail(d, R"({"op":"move_table","id":1,"x":100,"y":100})");
    cmd(d, R"({"op":"view","zoom":2,"panX":100,"panY":200,"calibration":1})");
    assert(subcard_document_save(d.get(), file.c_str()));
    auto locked = own(subcard_document_open(file.c_str()));
    assert(subcard_document_schema_is_locked(locked.get()));
    assert(subcard_document_mode(locked.get()) == SUBCARD_MODE_USE);
    // A snapshot contains layout and viewport; later edits stay dirty on accept.
    auto snap = subcard_document_snapshot(d.get());
    assert(snap);
    cmd(d, R"({"op":"view","zoom":3,"panX":100,"panY":200,"calibration":1})");
    assert(subcard_document_accept_snapshot(d.get(), snap, file.c_str()));
    assert(subcard_document_is_changed(d.get()));
    subcard_snapshot_close(snap);
    // Reject invalid persisted metadata and don't clobber a legacy SQL model.
    auto self = own(subcard_document_new());
    cmd(self, R"({"op":"add_table","name":"Tree","x":30,"y":40})");
    cmd(self, R"({"op":"add_index","table":1,"name":"parent","kind":"secondary"})");
    cmd(self, R"({"op":"connect","table":1,"field":2,"target":1,"targetField":0})");
    cmd(self, R"({"op":"delete_index","table":1,"id":2})");
    assert(graph(self).find("\"edges\":[]") != std::string::npos);
    cmd(self, R"({"op":"undo"})");
    assert(graph(self).find("\"targetField\":0") != std::string::npos);
    auto legacy = own(subcard_document_new());
    assert(subcard_document_replace_user_schema(legacy.get(),
                                                "CREATE TABLE user_legacy(id INTEGER PRIMARY KEY)"));
    fail(legacy, R"({"op":"add_table","name":"Legacy","x":0,"y":0})");
    sql(demo, "ALTER TABLE user_t1 ADD COLUMN unexpected TEXT");
    assert(!subcard_document_open(demo.c_str()));
    // Restore the visual test fixture without the intentionally damaged schema.
    auto demoSnapshot = subcard_document_snapshot(reopened.get());
    assert(demoSnapshot);
    {
        std::ofstream out(demo, std::ios::binary);
        out.write(static_cast<const char *>(subcard_snapshot_bytes(demoSnapshot)),
                  subcard_snapshot_size(demoSnapshot));
    }
    subcard_snapshot_close(demoSnapshot);
    sql(file,
        "UPDATE subcard_system_er_view SET json='{\"zoom\":0,\"panX\":0,\"panY\":0,\"calibration\":1}'");
    assert(!subcard_document_open(file.c_str()));
    std::cout << "ER commands, generated keys/constraints, history, locks, persistence and viewport tests "
                 "passed.\n";
}
