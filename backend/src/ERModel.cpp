// SPDX-License-Identifier: Apache-2.0
#include "ERModel.h"
#include "UTF8.h"
#include "sqlite3.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <set>
#include <stdexcept>

namespace subcard {
namespace {
void require(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
void check(int code, sqlite3 *db) {
    if (code != SQLITE_ROW && code != SQLITE_DONE && code != SQLITE_OK)
        throw std::runtime_error(sqlite3_errmsg(db));
}
void exec(sqlite3 *db, const std::string &sql) {
    check(sqlite3_exec(db, sql.c_str(), nullptr, nullptr, nullptr), db);
}
struct Query {
    sqlite3 *db;
    sqlite3_stmt *p = nullptr;
    Query(sqlite3 *db, const std::string &sql) : db(db) {
        check(sqlite3_prepare_v2(db, sql.c_str(), -1, &p, nullptr), db);
    }
    ~Query() { sqlite3_finalize(p); }
    void bind(int n, const std::string &s) {
        check(sqlite3_bind_text(p, n, s.c_str(), static_cast<int>(s.size()), SQLITE_TRANSIENT), db);
    }
    bool step() {
        int code = sqlite3_step(p);
        check(code, db);
        return code == SQLITE_ROW;
    }
    std::string text(int n = 0) {
        const auto *s = sqlite3_column_text(p, n);
        return s ? std::string(reinterpret_cast<const char *>(s), sqlite3_column_bytes(p, n)) : "";
    }
};
struct JSON {
    sqlite3 *db;
    std::string value;
    JSON(sqlite3 *db, std::string s) : db(db), value(std::move(s)) {
        require(value.size() <= 1024 * 1024, "ER command exceeds 1 MiB.");
        Query q(db, "SELECT json_valid(?1) AND json_type(?1)='object'");
        q.bind(1, value);
        require(q.step() && sqlite3_column_int(q.p, 0), "Expected a JSON object.");
    }
    std::string type(const char *key) const {
        Query q(db, "SELECT json_type(?1,?2)");
        q.bind(1, value);
        q.bind(2, std::string("$.") + key);
        q.step();
        return q.text();
    }
    std::string str(const char *key) const {
        require(type(key) == "text", "Missing or invalid text property.");
        Query q(db, "SELECT json_extract(?1,?2)");
        q.bind(1, value);
        q.bind(2, std::string("$.") + key);
        q.step();
        std::string s = q.text();
        require(s.find('\0') == std::string::npos && s.size() <= 256, "Invalid or oversized text.");
        return s;
    }
    double number(const char *key, double limit = 1000000) const {
        auto t = type(key);
        require(t == "integer" || t == "real", "Missing or invalid numeric property.");
        Query q(db, "SELECT json_extract(?1,?2)");
        q.bind(1, value);
        q.bind(2, std::string("$.") + key);
        q.step();
        double n = sqlite3_column_double(q.p, 0);
        require(std::isfinite(n) && std::abs(n) <= limit, "Number out of range.");
        return n;
    }
    int id(const char *key) const {
        double n = number(key);
        require(n >= 0 && n == std::floor(n), "Invalid object ID.");
        return static_cast<int>(n);
    }
    bool boolean(const char *key) const {
        auto t = type(key);
        require(t == "true" || t == "false", "Expected a boolean.");
        return t == "true";
    }
    std::vector<JSON> array(const char *key) const {
        require(type(key) == "array", "Expected an array.");
        Query q(db, "SELECT value FROM json_each(?1,?2)");
        q.bind(1, value);
        q.bind(2, std::string("$.") + key);
        std::vector<JSON> result;
        while (q.step()) {
            require(result.size() < 10000, "Too many objects.");
            result.emplace_back(db, q.text());
        }
        return result;
    }
    JSON object(const char *key) const {
        require(type(key) == "object", "Expected an object.");
        Query q(db, "SELECT json_extract(?1,?2)");
        q.bind(1, value);
        q.bind(2, std::string("$.") + key);
        q.step();
        return JSON(db, q.text());
    }
};
std::string quote(sqlite3 *db, const std::string &s) {
    Query q(db, "SELECT json_quote(?1)");
    q.bind(1, s);
    q.step();
    return q.text();
}
std::string num(double n) { return std::to_string(n); }
std::string num(int n) { return std::to_string(n); }
std::string graph_json(sqlite3 *db, const ERGraph &g) {
    std::string s = "{\"version\":1,\"tables\":[";
    bool first = true;
    for (const auto &t : g.tables) {
        if (!first)
            s += ",";
        first = false;
        s += "{\"id\":" + num(t.id) + ",\"name\":" + quote(db, t.name) + ",\"color\":" + quote(db, t.color) +
             ",\"x\":" + num(t.x) + ",\"y\":" + num(t.y) + ",\"fields\":[";
        bool f = true;
        for (const auto &v : t.fields) {
            if (!f)
                s += ",";
            f = false;
            s += "{\"id\":" + num(v.id) + ",\"name\":" + quote(db, v.name) +
                 ",\"kind\":" + quote(db, v.kind) + ",\"unique\":" + (v.unique ? "true" : "false") + "}";
        }
        s += "]}";
    }
    s += "],\"edges\":[";
    first = true;
    for (const auto &e : g.edges) {
        if (!first)
            s += ",";
        first = false;
        s += "{\"id\":" + num(e.id) + ",\"table\":" + num(e.table) + ",\"field\":" + num(e.field) +
             ",\"target\":" + num(e.target) + ",\"targetField\":" + num(e.targetField) +
             ",\"many\":" + (e.many ? "true" : "false") + ",\"cascade\":" + (e.cascade ? "true" : "false") +
             "}";
    }
    return s + "]}";
}
ERTable table_from(const JSON &j) {
    ERTable t{j.id("id"), j.str("name"), j.str("color"), j.number("x"), j.number("y"), {}};
    for (auto &f : j.array("fields"))
        t.fields.push_back({f.id("id"), f.str("name"), f.str("kind"), f.type("unique").empty() ? true : f.boolean("unique")});
    return t;
}
ERGraph graph_from(const JSON &j) {
    require(j.id("version") == 1, "Unsupported ER model version.");
    ERGraph g;
    for (auto &t : j.array("tables"))
        g.tables.push_back(table_from(t));
    for (auto &e : j.array("edges"))
        g.edges.push_back({e.id("id"), e.id("table"), e.id("field"), e.id("target"), e.id("targetField"),
                           e.boolean("many"), e.boolean("cascade")});
    return g;
}
ERTable &table(ERGraph &g, int id) {
    for (auto &t : g.tables)
        if (t.id == id)
            return t;
    throw std::runtime_error("Table no longer exists.");
}
ERField &field(ERTable &t, int id) {
    for (auto &f : t.fields)
        if (f.id == id)
            return f;
    throw std::runtime_error("Field no longer exists.");
}
EREdge &edge(ERGraph &g, int id) {
    for (auto &e : g.edges)
        if (e.id == id)
            return e;
    throw std::runtime_error("Connection no longer exists.");
}
std::string lower(std::string s) {
    for (char &c : s)
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}
void name(const std::string &s) {
    require(valid_utf8(s), "Names must be valid UTF-8.");
    require(!s.empty() && s.size() <= 128 && s.find_first_not_of(" \t\r\n") != std::string::npos,
            "Names must contain 1–128 UTF-8 bytes.");
    for (unsigned char c : s)
        require(c >= 32 && c != 127, "Names cannot contain control characters.");
}
int validate(ERGraph &g) {
    require(g.tables.size() <= 1000 && g.edges.size() <= 10000, "ER model is too large.");
    std::set<int> ids;
    std::set<std::string> names;
    int highest = 0;
    auto id = [&](int n) {
        require(n > 0 && n < 1000000 && ids.insert(n).second, "Duplicate or invalid ER ID.");
        highest = std::max(highest, n);
    };
    for (auto &t : g.tables) {
        id(t.id);
        name(t.name);
        require(names.insert(lower(t.name)).second, "Table names must be unique.");
        require(std::isfinite(t.x) && std::isfinite(t.y) && t.x >= 0 && t.y >= 0 && t.x <= 100000 &&
                    t.y <= 100000,
                "Table position is out of range.");
        require(t.color.size() == 7 && t.color[0] == '#' &&
                    std::all_of(t.color.begin() + 1, t.color.end(),
                                [](unsigned char c) { return std::isxdigit(c); }),
                "Expected a #RRGGBB color.");
        require(t.fields.size() <= 128, "Too many indexed fields.");
        std::set<std::string> fn{"id"};
        for (auto &f : t.fields) {
            id(f.id);
            name(f.name);
            require(fn.insert(lower(f.name)).second, "Field names must be unique, including id.");
            require(f.kind == "index" || f.kind == "secondary", "Unknown field kind.");
        }
    }
    std::set<int> connected;
    for (auto &e : g.edges) {
        id(e.id);
        auto &source = field(table(g, e.table), e.field);
        auto &target = table(g, e.target);
        require(source.kind == "secondary", "Connections must start at a foreign-key field.");
        require(!e.targetField || (field(target, e.targetField).kind == "index" && field(target, e.targetField).unique),
                "Connections must end at a primary key or a unique index.");
        require(connected.insert(e.field).second, "This foreign-key field already has a connection.");
        require(e.many || !e.cascade, "Cascade applies only to one-to-many connections.");
    }
    return highest;
}
std::string schema(const ERGraph &g) {
    std::string sql;
    for (const auto &t : g.tables) {
        sql += "CREATE TABLE user_t" + std::to_string(t.id) + "(id INTEGER PRIMARY KEY AUTOINCREMENT";
        for (const auto &f : t.fields) {
            sql += ",f" + std::to_string(f.id) + " INTEGER";
            if (f.kind == "index" && f.unique)
                sql += " UNIQUE";
            for (const auto &e : g.edges)
                if (e.table == t.id && e.field == f.id) {
                    if (!e.many)
                        sql += " UNIQUE";
                    sql += " REFERENCES user_t" + std::to_string(e.target) + "(" +
                           (e.targetField ? "f" + std::to_string(e.targetField) : "id") + ") ON DELETE " +
                           (e.cascade ? "CASCADE" : "RESTRICT");
                }
        }
        sql += ") STRICT;";
        for (const auto &f : t.fields)
            if (f.kind == "secondary" || !f.unique)
                sql += "CREATE INDEX user_i" + std::to_string(f.id) + " ON user_t" + std::to_string(t.id) +
                       "(f" + std::to_string(f.id) + ");";
    }
    return sql;
}
void store(sqlite3 *db, const char *tableName, const std::string &json) {
    Query q(db, std::string("UPDATE ") + tableName + " SET json=?1 WHERE id=1");
    q.bind(1, json);
    q.step();
}
std::string view_json(const ERModel &m) {
    return "{\"zoom\":" + num(m.zoom) + ",\"panX\":" + num(m.panX) + ",\"panY\":" + num(m.panY) +
           ",\"calibration\":" + num(m.calibration) + "}";
}
} // namespace
void initialize_er(sqlite3 *db, ERModel &m) {
    exec(db, "CREATE TABLE IF NOT EXISTS subcard_system_er_model(id INTEGER PRIMARY KEY CHECK(id=1),json "
             "TEXT NOT NULL) STRICT;"
             "INSERT OR IGNORE INTO subcard_system_er_model "
             "VALUES(1,'{\"version\":1,\"tables\":[],\"edges\":[]}');"
             "CREATE TABLE IF NOT EXISTS subcard_system_er_view(id INTEGER PRIMARY KEY CHECK(id=1),json TEXT "
             "NOT NULL) STRICT;"
             "INSERT OR IGNORE INTO subcard_system_er_view "
             "VALUES(1,'{\"zoom\":1,\"panX\":0,\"panY\":0,\"calibration\":1}');");
    Query q(db, "SELECT json FROM subcard_system_er_model WHERE id=1");
    require(q.step(), "Missing ER model.");
    m.graph = graph_from(JSON(db, q.text()));
    m.nextID = validate(m.graph) + 1;
    if (!m.graph.tables.empty()) {
        const auto expected = schema(m.graph);
        Query actual(db, "SELECT sql FROM sqlite_schema WHERE substr(name,1,5)='user_' AND sql IS NOT NULL");
        size_t count = 0;
        while (actual.step()) {
            require(expected.find(actual.text() + ";") != std::string::npos,
                    "ER metadata and user schema do not match.");
            ++count;
        }
        require(count == static_cast<size_t>(std::count(expected.begin(), expected.end(), ';')),
                "ER schema objects are missing.");
    }
    Query v(db, "SELECT json FROM subcard_system_er_view WHERE id=1");
    require(v.step(), "Missing ER viewport.");
    JSON j(db, v.text());
    m.zoom = j.number("zoom");
    m.panX = j.number("panX", 1e9);
    m.panY = j.number("panY", 1e9);
    m.calibration = j.number("calibration");
    require(m.zoom >= .0001 && m.zoom <= 4 && m.calibration >= .25 &&
                m.calibration <= 4,
            "Invalid ER viewport.");
    m.content = graph_json(db, m.graph) + view_json(m);
}
std::string er_json(sqlite3 *db, const ERModel &m) {
    auto s = graph_json(db, m.graph);
    s.pop_back();
    return s + ",\"view\":" + view_json(m) + ",\"canUndo\":" + (m.undo.empty() ? "false" : "true") +
           ",\"canRedo\":" + (m.redo.empty() ? "false" : "true") + "}";
}
bool er_command(sqlite3 *db, ERModel &m, DocumentState &state, SubCardMode mode, const char *command) {
    require(command, "Invalid command.");
    JSON j(db, command);
    auto op = j.str("op");
    if (op == "view") {
        ERModel v;
        v.zoom = j.number("zoom");
        v.panX = j.number("panX", 1e9);
        v.panY = j.number("panY", 1e9);
        v.calibration = j.number("calibration");
        require(v.zoom >= .0001 && v.zoom <= 4 && v.calibration >= .25 &&
                    v.calibration <= 4,
                "Viewport out of range.");
        if (view_json(m) == view_json(v))
            return false;
        auto content = graph_json(db, m.graph) + view_json(v);
        store(db, "subcard_system_er_view", view_json(v));
        m.content.swap(content);
        m.zoom = v.zoom;
        m.panX = v.panX;
        m.panY = v.panY;
        m.calibration = v.calibration;
        return true;
    }
    require(mode == SUBCARD_MODE_EDIT, "Return to editing mode first.");
    bool history = op == "undo" || op == "redo", undo = op == "undo";
    auto g = m.graph;
    int next = m.nextID;
    bool changesSchema = true;
    if (history) {
        auto &list = undo ? m.undo : m.redo;
        require(!list.empty(), "No action to undo or redo.");
        g = undo ? list.back().before : list.back().after;
        changesSchema = list.back().schema;
    } else if (op == "add_table") {
        g.tables.push_back({next++, j.str("name"), "#397DB8", j.number("x"), j.number("y"), {}});
    } else if (op == "paste_table") {
        auto t = table_from(j.object("table"));
        t.id = next++;
        // Reserve room for a unique copy suffix without splitting UTF-8.
        if (t.name.size() > 112) {
            t.name.resize(112);
            while (!valid_utf8(t.name))
                t.name.pop_back();
        }
        t.name += " copy";
        auto base = t.name;
        int suffix = 2;
        while (std::any_of(g.tables.begin(), g.tables.end(),
                           [&](const auto &other) { return lower(t.name) == lower(other.name); }))
            t.name = base + " " + std::to_string(suffix++);
        t.x = std::min(100000., t.x + 40);
        t.y = std::min(100000., t.y + 40);
        for (auto &f : t.fields)
            f.id = next++;
        g.tables.push_back(t);
    } else if (op == "update_table") {
        auto &t = table(g, j.id("id"));
        auto n = j.str("name");
        changesSchema = false;
        t.name = n;
        t.color = j.str("color");
    } else if (op == "move_table") {
        auto &t = table(g, j.id("id"));
        t.x = j.number("x");
        t.y = j.number("y");
        changesSchema = false;
    } else if (op == "delete_table") {
        int id = j.id("id");
        table(g, id);
        g.tables.erase(
            std::remove_if(g.tables.begin(), g.tables.end(), [&](const auto &t) { return t.id == id; }),
            g.tables.end());
        g.edges.erase(std::remove_if(g.edges.begin(), g.edges.end(),
                                     [&](auto &e) { return e.table == id || e.target == id; }),
                      g.edges.end());
    } else if (op == "add_index") {
        table(g, j.id("table")).fields.push_back({next++, j.str("name"), j.str("kind"), j.type("unique").empty() ? true : j.boolean("unique")});
    } else if (op == "update_index") {
        auto &f = field(table(g, j.id("table")), j.id("id"));
        f.name = j.str("name");
        changesSchema = false;
        if (!j.type("unique").empty()) {
            require(f.kind == "index", "Uniqueness is an index property.");
            const bool unique = j.boolean("unique");
            changesSchema = unique != f.unique;
            f.unique = unique;
        }
    } else if (op == "delete_index") {
        int id = j.id("id");
        auto &t = table(g, j.id("table"));
        field(t, id);
        t.fields.erase(std::remove_if(t.fields.begin(), t.fields.end(), [&](auto &f) { return f.id == id; }),
                       t.fields.end());
        g.edges.erase(std::remove_if(g.edges.begin(), g.edges.end(),
                                     [&](auto &e) { return e.field == id || e.targetField == id; }),
                      g.edges.end());
    } else if (op == "connect") {
        const int sourceTable = j.id("table"), sourceField = j.id("field");
        auto found = std::find_if(g.edges.begin(), g.edges.end(), [&](const auto &e) {
            return e.table == sourceTable && e.field == sourceField;
        });
        if (found == g.edges.end())
            g.edges.push_back({next++, sourceTable, sourceField, j.id("target"), j.id("targetField"), true, false});
        else {
            found->target = j.id("target");
            found->targetField = j.id("targetField");
        }
    } else if (op == "update_connection") {
        auto &e = edge(g, j.id("id"));
        e.many = j.boolean("many");
        e.cascade = e.many && j.boolean("cascade");
    } else if (op == "delete_connection") {
        int id = j.id("id");
        edge(g, id);
        g.edges.erase(std::remove_if(g.edges.begin(), g.edges.end(), [&](auto &e) { return e.id == id; }),
                      g.edges.end());
    } else
        throw std::runtime_error("Unknown ER command.");
    validate(g);
    auto json = graph_json(db, g);
    require(json.size() <= 1024 * 1024, "ER model exceeds 1 MiB.");
    if (json == graph_json(db, m.graph))
        return false;
    // Label edits are still schema edits, even though stable SQL IDs need no DDL.
    bool labels = op == "update_index" ||
                  (op == "update_table" && table(g, j.id("id")).name != table(m.graph, j.id("id")).name);
    require(!state.schema_locked || (!changesSchema && !labels),
            "The user schema is locked because this document has held real data.");
    if (changesSchema) {
        require(state.data_kind != SUBCARD_DATA_FAKE,
                "Discard fake data explicitly before changing the schema.");
        if (m.graph.tables.empty()) {
            Query legacy(
                db, "SELECT count(*) FROM sqlite_schema WHERE type='table' AND substr(name,1,5)='user_'");
            legacy.step();
            require(sqlite3_column_int(legacy.p, 0) == 0,
                    "Existing SQL schema has no ER metadata; it cannot be replaced by the canvas.");
        }
    }
    // Allocate history before committing. Keep database and in-memory graph aligned.
    auto newUndo = m.undo, newRedo = m.redo;
    if (history) {
        auto &from = undo ? newUndo : newRedo;
        auto &to = undo ? newRedo : newUndo;
        to.push_back(from.back());
        from.pop_back();
    } else {
        newUndo.push_back({m.graph, g, changesSchema});
        newRedo.clear();
        if (newUndo.size() > 200)
            newUndo.erase(newUndo.begin());
    }
    auto content = json + view_json(m);
    auto newState = state;
    exec(db, "SAVEPOINT subcard_er_command");
    try {
        if (changesSchema)
            newState = replace_user_schema(db, state, mode, schema(g).c_str());
        store(db, "subcard_system_er_model", json);
        exec(db, "RELEASE subcard_er_command");
    } catch (...) {
        sqlite3_exec(db, "ROLLBACK TO subcard_er_command; RELEASE subcard_er_command", nullptr, nullptr,
                     nullptr);
        throw;
    }
    m.content.swap(content);
    state = newState;
    m.graph = std::move(g);
    m.nextID = next;
    m.undo = std::move(newUndo);
    m.redo = std::move(newRedo);
    return true;
}
} // namespace subcard
