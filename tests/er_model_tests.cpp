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
std::string join_plan(const std::string &file, const char *query = "EXPLAIN QUERY PLAN SELECT b.id FROM user_t1 a JOIN user_t2 b ON b.r3=a.id WHERE a.id=1") {
    sqlite3 *db = nullptr;
    assert(sqlite3_open(file.c_str(), &db) == SQLITE_OK);
    sqlite3_stmt *q = nullptr;
    assert(sqlite3_prepare_v2(db, query, -1, &q, nullptr) == SQLITE_OK);
    std::string plan;
    int result;
    while ((result = sqlite3_step(q)) == SQLITE_ROW)
        plan += reinterpret_cast<const char *>(sqlite3_column_text(q, 3));
    assert(result == SQLITE_DONE);
    sqlite3_finalize(q);
    sqlite3_close(db);
    return plan;
}
// User-facing arrows point A -> B; only the backend knows about B's indexed key.
void table_relationships(const std::filesystem::path &directory) {
    auto d = own(subcard_document_new());
    cmd(d, R"({"op":"add_table","name":"Customers","x":10,"y":10})"); // 1
    cmd(d, R"({"op":"add_table","name":"Orders","x":500,"y":10})"); // 2
    fail(d, R"({"op":"add_connection","table":1,"target":999})");
    fail(d, R"({"op":"add_connection","table":1,"target":2,"many":"many"})");
    fail(d, R"({"op":"connect","table":1,"field":0,"target":2,"targetField":0})");
    cmd(d, R"({"op":"add_connection","table":1,"target":2})"); // 3
    const auto path = (directory / "table-relationships.subcard").string();
    auto save = [&] { assert(subcard_document_save(d.get(), path.c_str())); };
    save();
    assert(graph(d).find("\"version\":2") != std::string::npos);
    assert(scalar(path, "SELECT count(*) FROM pragma_table_info('user_t1')") == "1");
    assert(scalar(path, "SELECT count(*) FROM pragma_table_info('user_t2')") == "2");
    assert(scalar(path, "SELECT json_array([table],[from],[to]) FROM pragma_foreign_key_list('user_t2')") ==
           "[\"user_t1\",\"r3\",\"id\"]");
    assert(scalar(path, "SELECT count(*) FROM pragma_index_info('user_r3') WHERE name='r3'") == "1");
    assert(scalar(path, "SELECT [unique] FROM pragma_index_list('user_t2') WHERE name='user_r3'") == "0");
    assert(scalar(path, "SELECT json_array_length(json,'$.tables[1].fields') FROM subcard_system_er_model") == "0");
    // Verify the planner uses both the parent primary key and the generated child index.
    const auto plan = join_plan(path);
    assert(plan.find("INTEGER PRIMARY KEY") != std::string::npos);
    assert(plan.find("USING COVERING INDEX user_r3") != std::string::npos);
    write(d, "INSERT INTO user_t1 DEFAULT VALUES; INSERT INTO user_t2(r3) VALUES(1),(1),(NULL)");
    assert(!subcard_document_write_user_data(d.get(), SUBCARD_DATA_FAKE, "INSERT INTO user_t2(r3) VALUES(999)"));
    assert(!subcard_document_write_user_data(d.get(), SUBCARD_DATA_FAKE, "DELETE FROM user_t1 WHERE id=1"));
    fail(d, R"({"op":"update_connection","id":3,"many":false,"cascade":false})");
    assert(subcard_document_discard_fake_data(d.get()));
    cmd(d, R"({"op":"update_connection","id":3,"many":false,"cascade":false})");
    save();
    assert(scalar(path, "SELECT count(*) FROM pragma_index_list('user_t2') WHERE [unique]=1") == "1");
    assert(scalar(path, "SELECT count(*) FROM pragma_index_info((SELECT name FROM pragma_index_list('user_t2') WHERE [unique]=1)) WHERE name='r3'") == "1");
    assert(scalar(path, "SELECT count(*) FROM sqlite_schema WHERE name='user_r3'") == "0");
    auto one = own(subcard_document_open(path.c_str()));
    write(one, "INSERT INTO user_t1 DEFAULT VALUES; INSERT INTO user_t2(r3) VALUES(1),(NULL),(NULL)");
    assert(!subcard_document_write_user_data(one.get(), SUBCARD_DATA_FAKE, "INSERT INTO user_t2(r3) VALUES(1)"));
    cmd(d, R"({"op":"undo"})");
    save();
    assert(scalar(path, "SELECT [unique] FROM pragma_index_list('user_t2') WHERE name='user_r3'") == "0");
    cmd(d, R"({"op":"redo"})");
    cmd(d, R"({"op":"update_connection","id":3,"many":true,"cascade":true})");
    write(d, "INSERT INTO user_t1 DEFAULT VALUES; INSERT INTO user_t2(r3) VALUES(1),(1); DELETE FROM user_t1 WHERE id=1");
    assert(subcard_document_data_kind(d.get()) == SUBCARD_DATA_NONE);
    cmd(d, R"({"op":"delete_connection","id":3})");
    save();
    assert(scalar(path, "SELECT count(*) FROM pragma_table_info('user_t2')") == "1");
    assert(scalar(path, "SELECT count(*) FROM pragma_index_list('user_t2')") == "0");
    cmd(d, R"({"op":"undo"})");
    save();
    assert(scalar(path, "SELECT count(*) FROM pragma_table_info('user_t2') WHERE name='r3'") == "1");
    auto reopened = own(subcard_document_open(path.c_str()));
    assert(graph(reopened).find("\"table\":1,\"field\":0,\"target\":2") != std::string::npos);
    cmd(d, R"({"op":"add_connection","table":1,"target":2,"many":false})"); // 4; parallel relationship
    cmd(d, R"({"op":"add_connection","table":1,"target":1})"); // 5; self relationship
    cmd(d, R"({"op":"add_connection","table":2,"target":1})"); // 6; cycle
    save();
    auto complex = own(subcard_document_open(path.c_str()));
    assert(scalar(path, "SELECT count(*) FROM pragma_foreign_key_list('user_t1')") == "2");
    assert(scalar(path, "SELECT count(*) FROM pragma_foreign_key_list('user_t2')") == "2");
    cmd(d, R"({"op":"delete_table","id":1})");
    save();
    assert(graph(d).find("\"edges\":[]") != std::string::npos);
    assert(scalar(path, "SELECT count(*) FROM pragma_table_info('user_t2')") == "1");
    cmd(d, R"({"op":"undo"})");
    save();
    auto restored = own(subcard_document_open(path.c_str()));
    write(restored, "INSERT INTO user_t1 DEFAULT VALUES", SUBCARD_DATA_REAL);
    fail(restored, R"({"op":"add_connection","table":1,"target":2})");
    fail(restored, R"({"op":"update_connection","id":3,"many":false,"cascade":false})");
    fail(restored, R"({"op":"delete_connection","id":3})");
    assert(subcard_document_set_mode(reopened.get(), SUBCARD_MODE_USE));
    fail(reopened, R"({"op":"add_connection","table":1,"target":2})");
    // A storage failure rolls back hidden columns, indexes, and history together.
    sql(path, "CREATE TRIGGER fail_relationship BEFORE UPDATE ON subcard_system_er_model BEGIN SELECT RAISE(ABORT,'injected failure'); END");
    auto rejected = own(subcard_document_open(path.c_str()));
    fail(rejected, R"({"op":"add_connection","table":1,"target":2})");
    assert(!subcard_document_is_changed(rejected.get()));
    const auto rollback = (directory / "relationship-rollback.subcard").string();
    auto snapshot = subcard_document_snapshot(rejected.get());
    assert(snapshot);
    {
        std::ofstream out(rollback, std::ios::binary);
        out.write(static_cast<const char *>(subcard_snapshot_bytes(snapshot)), subcard_snapshot_size(snapshot));
        assert(out.good());
    }
    subcard_snapshot_close(snapshot);
    assert(scalar(rollback, "SELECT count(*) FROM pragma_foreign_key_list('user_t2')") == "2");
    // Version-1 documents keep their existing physical keys, rows and schema lock.
    auto legacy = own(subcard_document_new());
    cmd(legacy, R"({"op":"add_table","name":"Parent","x":10,"y":10})");
    cmd(legacy, R"({"op":"add_table","name":"Child","x":500,"y":10})");
    cmd(legacy, R"({"op":"add_index","table":2,"name":"parent","kind":"secondary"})");
    cmd(legacy, R"({"op":"connect","table":2,"field":3,"target":1,"targetField":0})");
    write(legacy, "INSERT INTO user_t1 DEFAULT VALUES; INSERT INTO user_t2(f3) VALUES(1)", SUBCARD_DATA_REAL);
    const auto legacyPath = (directory / "legacy-relationship-real.subcard").string();
    assert(subcard_document_save(legacy.get(), legacyPath.c_str()));
    sql(legacyPath, "UPDATE subcard_system_er_model SET json=json_set(json,'$.version',1)");
    auto old = own(subcard_document_open(legacyPath.c_str()));
    assert(subcard_document_schema_is_locked(old.get()));
    assert(subcard_document_set_mode(old.get(), SUBCARD_MODE_EDIT));
    cmd(old, R"({"op":"move_table","id":1,"x":30,"y":20})");
    assert(subcard_document_save(old.get(), legacyPath.c_str()));
    assert(scalar(legacyPath, "SELECT f3 FROM user_t2") == "1");
    assert(scalar(legacyPath, "SELECT [table] FROM pragma_foreign_key_list('user_t2')") == "user_t1");
    assert(scalar(legacyPath, "SELECT json_extract(json,'$.version') FROM subcard_system_er_model") == "2");
    std::cout << "Table relationship direction, automatic indexes, cardinality, history and persistence passed.\n";
}
// Ordinary fields exist only in the inspector; the core owns their persistent schema.
void typed_fields(const std::filesystem::path &directory) {
    auto d = own(subcard_document_new());
    cmd(d, R"({"op":"add_table","name":"People","x":10,"y":10})");
    const char *kinds[] = {"string", "url", "date", "time", "datetime", "decimal", "float", "integer", "boolean", "blob"};
    for (const auto *kind : kinds)
        cmd(d, std::string(R"({"op":"add_field","table":1,"name":")") + kind + R"(","kind":")" + kind + R"("})");
    assert(graph(d).find("\"version\":3") != std::string::npos);
    fail(d, R"({"op":"add_field","table":1,"name":"unknown","kind":"money"})");
    fail(d, R"({"op":"add_field","table":1,"name":"ID","kind":"integer"})");
    fail(d, R"({"op":"add_field","table":1,"name":"String","kind":"string"})");
    fail(d, R"({"op":"update_field","table":1,"id":2,"indexed":"yes"})");
    fail(d, R"({"op":"update_field","table":1,"id":2,"unique":"yes"})");
    fail(d, R"({"op":"update_field","table":1,"id":2,"media":"image"})");
    fail(d, R"({"op":"update_field","table":1,"id":11,"media":"executable"})");
    fail(d, R"({"op":"update_field","table":1,"id":7,"scale":19})");
    fail(d, R"({"op":"update_field","table":1,"id":7,"scale":1.5})");
    fail(d, R"({"op":"update_field","table":1,"id":7,"indexed":true})");
    fail(d, R"({"op":"update_field","table":1,"id":11,"indexed":true})");
    fail(d, R"({"op":"update_field","table":1,"id":2,"kind":"index"})");
    fail(d, R"({"op":"update_index","table":1,"id":2,"name":"bad"})");
    fail(d, R"({"op":"add_index","table":1,"name":"bad","kind":"string","unique":false})");
    fail(d, R"({"op":"delete_index","table":1,"id":2})");
    cmd(d, R"({"op":"update_field","table":1,"id":2,"indexed":true})");
    cmd(d, R"({"op":"update_field","table":1,"id":3,"indexed":true,"unique":true})");
    cmd(d, R"({"op":"update_field","table":1,"id":4,"indexed":true})");
    cmd(d, R"({"op":"update_field","table":1,"id":9,"indexed":true})");
    cmd(d, R"({"op":"update_field","table":1,"id":11,"media":"image","name":"Portrait"})");
    const auto file = (directory / "typed-fields.subcard").string();
    auto save = [&] { assert(subcard_document_save(d.get(), file.c_str())); };
    save();
    assert(scalar(file, "SELECT group_concat(type,',') FROM pragma_table_info('user_t1')") == "INTEGER,TEXT,TEXT,TEXT,TEXT,TEXT,BLOB,REAL,INTEGER,INTEGER,BLOB");
    assert(scalar(file, "SELECT count(*) FROM pragma_index_list('user_t1')") == "4");
    assert(scalar(file, "SELECT count(*) FROM pragma_index_list('user_t1') WHERE [unique]=1") == "1");
    assert(scalar(file, "SELECT count(*) FROM pragma_index_info('user_i2') WHERE name='f2'") == "1");
    // Actual query plans, not just metadata, prove the optional index is usable.
    assert(join_plan(file, "EXPLAIN QUERY PLAN SELECT id FROM user_t1 WHERE f2='Zoë'").find("USING COVERING INDEX user_i2") != std::string::npos);
    assert(join_plan(file, "EXPLAIN QUERY PLAN SELECT id FROM user_t1 WHERE f4>='2024-01-01'").find("USING COVERING INDEX user_i4") != std::string::npos);
    write(d, "INSERT INTO user_t1(f2,f3,f4,f5,f6,f7,f8,f9,f10,f11) VALUES('Zoë','https://example.com','2024-02-29','23:59:59','2024-02-29T23:59:59Z',x'0000000000000012345C',1.25,-42,1,x'89504e47000aff')");
    write(d, "INSERT INTO user_t1(f2,f3) VALUES('Zoë','mailto:person@example.com'); INSERT INTO user_t1 DEFAULT VALUES");
    write(d, "INSERT INTO user_t1(f7) VALUES(x'0000000000000012345D'),(x'0000000000000000000C')");
    for (const auto *sql : {
        "INSERT INTO user_t1(f3) VALUES('https://example.com')", // unique
        "INSERT INTO user_t1(f3) VALUES('relative/path')",
        "INSERT INTO user_t1(f3) VALUES('https://bad url')",
        "INSERT INTO user_t1(f3) VALUES('1bad:value')",
        "INSERT INTO user_t1(f3) VALUES('https:')",
        "INSERT INTO user_t1(f4) VALUES('2023-02-29')",
        "INSERT INTO user_t1(f4) VALUES('2024-04-31')",
        "INSERT INTO user_t1(f4) VALUES('2024-2-01')",
        "INSERT INTO user_t1(f4) VALUES('2024-02-29'||char(0))",
        "INSERT INTO user_t1(f5) VALUES('12:00:00'||char(0))",
        "INSERT INTO user_t1(f6) VALUES('2024-02-29T23:59:59Z'||char(0))",
        "INSERT INTO user_t1(f3) VALUES('https://example.org'||char(0))",
        "INSERT INTO user_t1(f5) VALUES('24:00:00')",
        "INSERT INTO user_t1(f5) VALUES('12:59:60')",
        "INSERT INTO user_t1(f6) VALUES('2024-02-29T23:59:59')",
        "INSERT INTO user_t1(f6) VALUES('2023-02-29T23:59:59Z')",
        "INSERT INTO user_t1(f7) VALUES(x'1000000000000012345C')", // invalid pad
        "INSERT INTO user_t1(f7) VALUES(x'0000000000000012345F')", // invalid sign
        "INSERT INTO user_t1(f7) VALUES(x'123C')", // wrong BCD size
        "INSERT INTO user_t1(f7) VALUES(x'000000000000001234AC')", // non-digit nibble
        "INSERT INTO user_t1(f7) VALUES(x'0000000000000000000D')", // negative zero
        "INSERT INTO user_t1(f8) VALUES('text')",
        "INSERT INTO user_t1(f9) VALUES(1.5)",
        "INSERT INTO user_t1(f10) VALUES(2)",
        "INSERT INTO user_t1(f11) VALUES('not binary')"})
        assert(!subcard_document_write_user_data(d.get(), SUBCARD_DATA_FAKE, sql));
    fail(d, R"({"op":"update_field","table":1,"id":2,"kind":"integer"})");
    fail(d, R"({"op":"update_field","table":1,"id":2,"indexed":false})");
    fail(d, R"({"op":"delete_field","table":1,"id":11})");
    // Labels keep stable columns, preserve bytes and do not discard fake rows.
    cmd(d, R"({"op":"update_field","table":1,"id":11,"name":"Photo"})");
    save();
    assert(scalar(file, "SELECT hex(f11) FROM user_t1 WHERE id=1") == "89504E47000AFF");
    assert(scalar(file, "SELECT hex(f7) FROM user_t1 WHERE id=1") == "0000000000000012345C");
    auto reopened = own(subcard_document_open(file.c_str()));
    assert(graph(reopened).find("\"media\":\"image\"") != std::string::npos);
    assert(graph(reopened).find("Photo") != std::string::npos);
    assert(subcard_document_discard_fake_data(d.get()));
    cmd(d, R"({"op":"update_field","table":1,"id":2,"kind":"blob","media":"document"})");
    save();
    assert(scalar(file, "SELECT count(*) FROM sqlite_schema WHERE name='user_i2'") == "0");
    cmd(d, R"({"op":"undo"})");
    save();
    assert(scalar(file, "SELECT count(*) FROM sqlite_schema WHERE name='user_i2'") == "1");
    cmd(d, R"({"op":"redo"})");
    cmd(d, R"({"op":"update_field","table":1,"id":7,"scale":4})");
    cmd(d, R"({"op":"delete_field","table":1,"id":11})");
    cmd(d, R"({"op":"undo"})");
    cmd(d, R"({"op":"update_field","table":1,"id":3,"indexed":false,"unique":false})");
    save();
    assert(scalar(file, "SELECT count(*) FROM pragma_index_list('user_t1') WHERE [unique]=1") == "0");
    // Duplicate keeps field metadata but remaps all IDs and has no relationships.
    sqlite3 *db = nullptr;
    assert(sqlite3_open(file.c_str(), &db) == SQLITE_OK);
    sqlite3_stmt *q = nullptr;
    assert(sqlite3_prepare_v2(db, "SELECT json_extract(json,'$.tables[0]') FROM subcard_system_er_model", -1, &q, nullptr) == SQLITE_OK);
    assert(sqlite3_step(q) == SQLITE_ROW);
    const std::string copy = reinterpret_cast<const char *>(sqlite3_column_text(q, 0));
    sqlite3_finalize(q); sqlite3_close(db);
    cmd(d, "{\"op\":\"paste_table\",\"table\":" + copy + "}");
    save();
    assert(scalar(file, "SELECT json_extract(json,'$.tables[1].fields[9].media') FROM subcard_system_er_model") == "image");
    assert(scalar(file, "SELECT json_extract(json,'$.tables[1].fields[5].scale') FROM subcard_system_er_model") == "4");
    auto duplicate = own(subcard_document_open(file.c_str()));
    write(d, "INSERT INTO user_t1(f11) VALUES(x'00010200ff')", SUBCARD_DATA_REAL);
    fail(d, R"({"op":"update_field","table":1,"id":11,"name":"Locked photo"})");
    fail(d, R"({"op":"update_field","table":1,"id":11,"media":"video"})");
    fail(d, R"({"op":"add_field","table":1,"name":"Locked","kind":"string"})");
    fail(d, R"({"op":"delete_field","table":1,"id":11})");
    save();
    auto real = own(subcard_document_open(file.c_str()));
    assert(subcard_document_schema_is_locked(real.get()));
    assert(scalar(file, "SELECT hex(f11) FROM user_t1") == "00010200FF");
    std::cout << "Typed field storage, validation, indexes, media bytes, locks, history and persistence passed.\n";
}
void field_rules(const std::filesystem::path &directory) {
    auto d = own(subcard_document_new());
    cmd(d, R"({"op":"add_table","name":"Rules","x":10,"y":10})");
    cmd(d, R"({"op":"add_field","table":1,"name":"Required unique","kind":"string","nullable":false,"unique":true})");
    cmd(d, R"({"op":"add_field","table":1,"name":"Optional unique","kind":"string","unique":true})");
    cmd(d, R"({"op":"add_field","table":1,"name":"Required repeated","kind":"integer","nullable":false})");
    cmd(d, R"({"op":"add_field","table":1,"name":"Optional repeated","kind":"string"})");
    fail(d, R"({"op":"add_field","table":1,"name":"Invalid","kind":"string","nullable":0})");
    fail(d, R"({"op":"update_field","table":1,"id":2,"nullable":null})");
    const auto file = (directory / "field-rules.subcard").string();
    auto save = [&] { assert(subcard_document_save(d.get(), file.c_str())); };
    save();
    assert(scalar(file, "SELECT json_extract(json,'$.version') FROM subcard_system_er_model") == "4");
    assert(scalar(file, "SELECT group_concat([notnull]) FROM pragma_table_info('user_t1') WHERE name!='id'") == "1,0,1,0");
    write(d, "INSERT INTO user_t1(f2,f4,f5) VALUES('one',7,'same'),('two',7,'same')");
    write(d, "UPDATE user_t1 SET f3='present' WHERE id=1");
    for (const auto *statement : {
        "INSERT INTO user_t1(f4) VALUES(7)",
        "INSERT INTO user_t1(f2,f4) VALUES(NULL,7)",
        "INSERT INTO user_t1(f2) VALUES('three')",
        "UPDATE user_t1 SET f2=NULL WHERE id=1",
        "UPDATE user_t1 SET f4=NULL WHERE id=1",
        "INSERT INTO user_t1(f2,f4) VALUES('one',7)",
        "UPDATE user_t1 SET f2='one' WHERE id=2",
        "UPDATE user_t1 SET f3='present' WHERE id=2",
        "INSERT INTO user_t1(f2,f4) VALUES('three',7); UPDATE user_t1 SET f2=NULL WHERE id=1"})
        assert(!subcard_document_write_user_data(d.get(), SUBCARD_DATA_FAKE, statement));
    save();
    assert(scalar(file, "SELECT count(*) FROM user_t1") == "2");
    fail(d, R"({"op":"update_field","table":1,"id":2,"nullable":true})");
    fail(d, R"({"op":"update_field","table":1,"id":3,"unique":false})");
    // Constraints belong to SQLite, including writes outside SubCard's API.
    sqlite3 *db = nullptr;
    assert(sqlite3_open(file.c_str(), &db) == SQLITE_OK);
    sqlite3_extended_result_codes(db, 1);
    assert(sqlite3_exec(db, "INSERT INTO user_t1(f4) VALUES(7)", nullptr, nullptr, nullptr) == SQLITE_CONSTRAINT_NOTNULL);
    assert(sqlite3_exec(db, "INSERT INTO user_t1(f2,f4) VALUES('one',7)", nullptr, nullptr, nullptr) == SQLITE_CONSTRAINT_UNIQUE);
    sqlite3_close(db);
    auto reopened = own(subcard_document_open(file.c_str()));
    assert(graph(reopened).find("\"nullable\":false") != std::string::npos);
    assert(subcard_document_discard_fake_data(d.get()));
    cmd(d, R"({"op":"update_field","table":1,"id":2,"nullable":true,"unique":false})");
    save();
    assert(scalar(file, "SELECT [notnull] FROM pragma_table_info('user_t1') WHERE name='f2'") == "0");
    cmd(d, R"({"op":"undo"})");
    save();
    assert(scalar(file, "SELECT [notnull] FROM pragma_table_info('user_t1') WHERE name='f2'") == "1");
    assert(scalar(file, "SELECT count(*) FROM pragma_index_list('user_t1') WHERE [unique]=1") == "2");
    cmd(d, R"({"op":"redo"})");
    cmd(d, R"({"op":"undo"})");
    // Optional lookup indexes and datatype changes preserve the two field rules.
    cmd(d, R"({"op":"update_field","table":1,"id":2,"indexed":true})");
    cmd(d, R"({"op":"update_field","table":1,"id":2,"indexed":false})");
    cmd(d, R"({"op":"update_field","table":1,"id":2,"kind":"blob"})");
    save();
    assert(scalar(file, "SELECT sql FROM sqlite_schema WHERE name='user_t1'").find("f2 BLOB NOT NULL UNIQUE") != std::string::npos);
    cmd(d, R"({"op":"undo"})");
    save();
    const auto copy = scalar(file, "SELECT json_extract(json,'$.tables[0]') FROM subcard_system_er_model");
    cmd(d, "{\"op\":\"paste_table\",\"table\":" + copy + "}");
    save();
    assert(scalar(file, "SELECT json_extract(json,'$.tables[1].fields[0].nullable') FROM subcard_system_er_model") == "0");
    assert(scalar(file, "SELECT json_extract(json,'$.tables[1].fields[0].unique') FROM subcard_system_er_model") == "1");
    auto copied = own(subcard_document_open(file.c_str()));
    write(d, "INSERT INTO user_t1(f2,f4) VALUES('',7)", SUBCARD_DATA_REAL); // NOT NULL allows empty text.
    fail(d, R"({"op":"update_field","table":1,"id":2,"nullable":true})");
    fail(d, R"({"op":"update_field","table":1,"id":3,"unique":false})");

    // Every datatype supports required/unique values, including BLOB and packed BCD.
    const char *kinds[] = {"string", "url", "date", "time", "datetime", "decimal", "float", "integer", "boolean", "blob"};
    const char *values[] = {"'value'", "'https://example.com'", "'2024-02-29'", "'23:59:59'", "'2024-02-29T23:59:59Z'", "x'0000000000000012345C'", "1.25", "42", "1", "x'000100ff'"};
    for (size_t i = 0; i < 10; ++i) {
        auto typed = own(subcard_document_new());
        cmd(typed, R"({"op":"add_table","name":"Typed rules","x":10,"y":10})");
        cmd(typed, std::string(R"({"op":"add_field","table":1,"name":"Value","nullable":false,"unique":true,"kind":")") + kinds[i] + "\"}");
        assert(!subcard_document_write_user_data(typed.get(), SUBCARD_DATA_FAKE, "INSERT INTO user_t1 DEFAULT VALUES"));
        auto statement = std::string("INSERT INTO user_t1(f2) VALUES(") + values[i] + ")";
        write(typed, statement.c_str());
        assert(!subcard_document_write_user_data(typed.get(), SUBCARD_DATA_FAKE, statement.c_str()));
        assert(!subcard_document_write_user_data(typed.get(), SUBCARD_DATA_FAKE, "UPDATE user_t1 SET f2=NULL"));
    }
    // Older typed documents omit nullable; reopening keeps their schema and rows intact.
    auto legacy = own(subcard_document_new());
    cmd(legacy, R"({"op":"add_table","name":"Old typed table","x":10,"y":10})");
    cmd(legacy, R"({"op":"add_field","table":1,"name":"Value","kind":"string"})");
    write(legacy, "INSERT INTO user_t1 DEFAULT VALUES", SUBCARD_DATA_REAL);
    assert(subcard_document_save(legacy.get(), file.c_str()));
    sql(file, "UPDATE subcard_system_er_model SET json=json_remove(json,'$.tables[0].fields[0].nullable')");
    auto old = own(subcard_document_open(file.c_str()));
    assert(graph(old).find("\"nullable\":true") != std::string::npos);
    assert(subcard_document_schema_is_locked(old.get()));
    assert(scalar(file, "SELECT f2 IS NULL FROM user_t1") == "1");
    std::cout << "Field nullability/uniqueness, all datatypes, history, locks and backward compatibility passed.\n";
}
int main(int argc, char **argv) {
    assert(argc == 2);
    std::filesystem::create_directories(argv[1]);
    table_relationships(argv[1]);
    typed_fields(argv[1]);
    field_rules(argv[1]);
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
