// SPDX-License-Identifier: Apache-2.0
#include "ERModel.h"
#include "UTF8.h"
#include "CheckExpression.h"
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
    std::string str(const char *key, size_t limit = 256) const {
        require(type(key) == "text", "Missing or invalid text property.");
        Query q(db, "SELECT json_extract(?1,?2)");
        q.bind(1, value);
        q.bind(2, std::string("$.") + key);
        q.step();
        std::string s = q.text();
        require(s.find('\0') == std::string::npos && s.size() <= limit, "Invalid or oversized text.");
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
bool legacy(const ERField &f) { return f.kind == "index" || f.kind == "secondary"; }
bool ordinary(const std::string &kind) {
    return kind == "string" || kind == "url" || kind == "date" || kind == "time" ||
           kind == "datetime" || kind == "decimal" || kind == "float" ||
           kind == "integer" || kind == "boolean" || kind == "blob";
}
bool indexable(const std::string &kind) { return ordinary(kind) && kind != "blob" && kind != "decimal"; }
std::vector<std::string> view_groups(const ERField &f) {
    if (f.kind == "blob") return {"none"};
    std::vector<std::string> groups{"none", "count"};
    if (f.kind == "integer" || f.kind == "float") {
        groups.push_back("sum"); groups.push_back("avg");
    }
    // Packed BCD byte ordering is not numeric ordering.
    if (f.kind != "decimal" && f.kind != "boolean") {
        groups.push_back("min"); groups.push_back("max");
    }
    return groups;
}
bool grouped(const ERDataView &v) {
    return std::any_of(v.columns.begin(), v.columns.end(), [](const auto &c) { return c.group != "none"; });
}
std::string data_view_sql(const ERDataView &v) {
    if (!v.table || v.columns.empty()) return "";
    std::string sql = "SELECT ";
    std::vector<std::string> keys;
    const bool aggregate = grouped(v);
    if (!aggregate) sql += "id AS \"__subcard_row_id\", ";
    for (size_t i = 0; i < v.columns.size(); ++i) {
        const auto &c = v.columns[i];
        const auto column = "f" + num(c.field);
        if (i) sql += ", ";
        if (c.group == "none") { sql += column; keys.push_back(column); }
        else sql += c.group + "(" + column + ") AS " + column + "_" + c.group;
    }
    sql += " FROM user_t" + num(v.table);
    if (aggregate && !keys.empty()) {
        sql += " GROUP BY ";
        for (size_t i = 0; i < keys.size(); ++i) { if (i) sql += ", "; sql += keys[i]; }
    }
    return sql;
}
std::vector<std::pair<std::string, std::string>> check_names(const ERTable &t, bool display = false) {
    std::vector<std::pair<std::string, std::string>> result;
    for (const auto &f : t.fields)
        if (!legacy(f)) result.emplace_back(display ? "f" + num(f.id) : f.name,
                                            display ? sql_identifier(f.name) : "f" + num(f.id));
    return result;
}
std::string user_check(const ERTable &t, const std::string &expression) {
    return rewrite_check(expression, check_names(t));
}
void validate_table_checks(const ERTable &t) {
    std::vector<std::string> columns;
    for (const auto &f : t.fields) if (!legacy(f)) columns.push_back("f" + num(f.id));
    for (const auto &f : t.fields) if (!f.check.empty()) validate_check_sql(f.check, columns);
    for (const auto &c : t.constraints) validate_check_sql(c.expression, columns);
}
std::string graph_json(sqlite3 *db, const ERGraph &g, bool display = false) {
    bool typed = false, rules = false, checks = false;
    for (const auto &t : g.tables)
    {
        checks = checks || !t.constraints.empty();
        for (const auto &f : t.fields) {
            typed = typed || !legacy(f);
            rules = rules || (!legacy(f) && (!f.nullable || (f.unique && !f.indexed)));
            checks = checks || !f.check.empty();
        }
    }
    const bool namedRelationships = std::any_of(g.edges.begin(), g.edges.end(), [](const auto &e) {
        return !e.referenceName.empty() || !e.inverseName.empty();
    });
    std::string s = std::string("{\"version\":") + (namedRelationships ? "7" : !g.views.empty() ? "6" : checks ? "5" : rules ? "4" : typed ? "3" : "2") + ",\"tables\":[";
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
                 ",\"kind\":" + quote(db, v.kind) + ",\"unique\":" + (v.unique ? "true" : "false");
            if (!legacy(v))
                s += ",\"indexed\":" + std::string(v.indexed ? "true" : "false") +
                     ",\"nullable\":" + (v.nullable ? "true" : "false") +
                     ",\"media\":" + quote(db, v.media) + ",\"scale\":" + num(v.scale);
            if (!v.check.empty()) {
                s += ",\"check\":" + quote(db, v.check);
                if (display) s += ",\"checkDisplay\":" + quote(db, rewrite_check(v.check, check_names(t, true)));
            }
            s += "}";
        }
        s += "]";
        if (!t.constraints.empty()) {
            s += ",\"constraints\":[";
            bool firstConstraint = true;
            for (const auto &c : t.constraints) {
                if (!firstConstraint) s += ",";
                firstConstraint = false;
                s += "{\"id\":" + num(c.id) + ",\"name\":" + quote(db, c.name) +
                     ",\"expression\":" + quote(db, c.expression);
                if (display) s += ",\"displayExpression\":" + quote(db, rewrite_check(c.expression, check_names(t, true)));
                s += "}";
            }
            s += "]";
        }
        s += "}";
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
             ",\"referenceName\":" + quote(db, e.referenceName) + ",\"inverseName\":" + quote(db, e.inverseName) + "}";
    }
    s += "]";
    if (!g.views.empty()) {
        s += ",\"views\":[";
        first = true;
        for (const auto &v : g.views) {
            if (!first) s += ",";
            first = false;
            s += "{\"id\":" + num(v.id) + ",\"name\":" + quote(db, v.name) +
                 ",\"table\":" + num(v.table) + ",\"x\":" + num(v.x) + ",\"y\":" + num(v.y) + ",\"columns\":[";
            bool firstColumn = true;
            for (const auto &c : v.columns) {
                if (!firstColumn) s += ",";
                firstColumn = false;
                s += "{\"field\":" + num(c.field) + ",\"group\":" + quote(db, c.group) + "}";
            }
            s += "]";
            if (display) {
                s += ",\"sql\":" + quote(db, data_view_sql(v)) + ",\"grouped\":" + (grouped(v) ? "true" : "false") + ",\"availableColumns\":[";
                bool firstField = true;
                for (const auto &t : g.tables) if (t.id == v.table) for (const auto &f : t.fields) if (!legacy(f)) {
                    if (!firstField) s += ",";
                    firstField = false;
                    s += "{\"field\":" + num(f.id) + ",\"name\":" + quote(db, f.name) + ",\"kind\":" + quote(db, f.kind) + ",\"groups\":[";
                    const auto groups = view_groups(f);
                    for (size_t i = 0; i < groups.size(); ++i) { if (i) s += ","; s += quote(db, groups[i]); }
                    s += "]}";
                }
                s += "]";
            }
            s += "}";
        }
        s += "]";
    }
    return s + "}";
}
ERTable table_from(const JSON &j) {
    ERTable t{j.id("id"), j.str("name"), j.str("color"), j.number("x"), j.number("y"), {}, {}};
    for (auto &f : j.array("fields")) {
        ERField v{f.id("id"), f.str("name"), f.str("kind")};
        v.unique = f.type("unique").empty() ? legacy(v) : f.boolean("unique");
        if (!f.type("indexed").empty()) v.indexed = f.boolean("indexed");
        if (!f.type("nullable").empty()) v.nullable = f.boolean("nullable");
        if (!f.type("media").empty()) v.media = f.str("media");
        if (!f.type("scale").empty()) v.scale = f.id("scale");
        if (!f.type("check").empty()) v.check = f.str("check", 4096);
        t.fields.push_back(v);
    }
    if (!j.type("constraints").empty())
        for (const auto &c : j.array("constraints"))
            t.constraints.push_back({c.id("id"), c.str("name"), c.str("expression", 4096)});
    return t;
}
ERGraph graph_from(const JSON &j) {
    require(j.id("version") >= 1 && j.id("version") <= 7, "Unsupported ER model version.");
    ERGraph g;
    for (auto &t : j.array("tables"))
        g.tables.push_back(table_from(t));
    for (auto &e : j.array("edges")) {
        require(j.id("version") >= 2 || e.id("field") != 0, "Version-1 edges require a foreign-key field.");
        g.edges.push_back({e.id("id"), e.id("table"), e.id("field"), e.id("target"), e.id("targetField"),
                           e.boolean("many"), e.boolean("cascade"),
                           e.type("referenceName").empty() ? "" : e.str("referenceName"),
                           e.type("inverseName").empty() ? "" : e.str("inverseName")});
    }
    if (!j.type("views").empty()) {
        require(j.id("version") >= 6, "Views require ER model version 6.");
        for (const auto &v : j.array("views")) {
            ERDataView view{v.id("id"), v.str("name"), v.id("table"), v.number("x"), v.number("y"), {}};
            for (const auto &c : v.array("columns")) view.columns.push_back({c.id("field"), c.str("group")});
            g.views.push_back(std::move(view));
        }
    }
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
ERDataView &data_view(ERGraph &g, int id) {
    for (auto &v : g.views) if (v.id == id) return v;
    throw std::runtime_error("View no longer exists.");
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
    require(g.tables.size() <= 1000 && g.edges.size() <= 10000 && g.views.size() <= 1000, "ER model is too large.");
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
        require(t.fields.size() <= 128, "A table supports at most 128 fields.");
        std::set<std::string> fn{"id"};
        for (auto &f : t.fields) {
            id(f.id);
            name(f.name);
            require(fn.insert(lower(f.name)).second, "Field names must be unique, including id.");
            require(legacy(f) || ordinary(f.kind), "Unknown field datatype.");
            if (!legacy(f)) {
                require(!f.indexed || indexable(f.kind), "Blob and packed BCD fields do not support optional lookup indexes.");
                require(f.media == "binary" || (f.kind == "blob" &&
                        (f.media == "image" || f.media == "video" || f.media == "sound" || f.media == "document")),
                        "Choose a valid blob purpose.");
                require(f.scale >= 0 && f.scale <= 18, "BCD scale must be between 0 and 18.");
            } else require(f.nullable && f.check.empty(), "Generated keys retain their existing rules.");
        }
        require(t.constraints.size() <= 32, "A table supports at most 32 named constraints.");
        std::set<std::string> constraintNames;
        for (const auto &c : t.constraints) {
            id(c.id);
            name(c.name);
            require(constraintNames.insert(lower(c.name)).second, "Constraint names must be unique within their table.");
        }
        validate_table_checks(t);
    }
    std::set<int> connected;
    for (auto &e : g.edges) {
        id(e.id);
        // Empty names remain valid only for relationships from older documents.
        if (!e.referenceName.empty()) name(e.referenceName);
        if (!e.inverseName.empty()) name(e.inverseName);
        if (e.field == 0) {
            table(g, e.table);
            table(g, e.target);
            require(e.targetField == 0, "Table relationships cannot name a destination key.");
            require(e.many || !e.cascade, "Cascade applies only to one-to-many connections.");
            continue;
        }
        auto &source = field(table(g, e.table), e.field);
        auto &target = table(g, e.target);
        require(source.kind == "secondary", "Connections must start at a foreign-key field.");
        require(!e.targetField || (field(target, e.targetField).kind == "index" && field(target, e.targetField).unique),
                "Connections must end at a primary key or a unique index.");
        require(connected.insert(e.field).second, "This foreign-key field already has a connection.");
        require(e.many || !e.cascade, "Cascade applies only to one-to-many connections.");
    }
    std::set<std::string> viewNames;
    for (const auto &v : g.views) {
        id(v.id); name(v.name);
        require(viewNames.insert(lower(v.name)).second, "View names must be unique.");
        require(std::isfinite(v.x) && std::isfinite(v.y) && v.x >= 0 && v.y >= 0 && v.x <= 100000 && v.y <= 100000,
                "View position is out of range.");
        require(v.table || v.columns.empty(), "Choose a source table first.");
        if (!v.table) continue;
        auto &t = table(g, v.table);
        std::set<int> selected;
        for (const auto &c : v.columns) {
            auto &f = field(t, c.field);
            require(!legacy(f), "Generated keys are not view columns.");
            require(selected.insert(c.field).second, "A view column can be selected only once.");
            const auto groups = view_groups(f);
            require(std::find(groups.begin(), groups.end(), c.group) != groups.end(), "This grouping is not supported for the column datatype.");
            require(!grouped(v) || f.kind != "blob", "Remove blob columns before choosing an aggregate.");
        }
    }
    return highest;
}
std::string date_rule(const std::string &v) {
    return "length(CAST(" + v + " AS BLOB))=10 AND " + v +
           " GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND date(" +
           v + ",'+0 days') IS " + v;
}
std::string time_rule(const std::string &v) {
    return "length(CAST(" + v + " AS BLOB))=8 AND " + v +
           " GLOB '[0-2][0-9]:[0-5][0-9]:[0-5][0-9]' AND substr(" + v + ",1,2)<'24'";
}
std::string field_check(const ERField &f, const std::string &col) {
    std::string rule;
    if (f.kind == "boolean") rule = col + " IN (0,1)";
    // Canonical ISO values preserve chronological order in ordinary indexes.
    if (f.kind == "date") rule = date_rule(col);
    if (f.kind == "time") rule = time_rule(col);
    if (f.kind == "datetime")
        rule = "length(CAST(" + col + " AS BLOB))=20 AND substr(" + col +
               ",11,1)='T' AND substr(" + col + ",20,1)='Z' AND " +
               date_rule("substr(" + col + ",1,10)") + " AND " + time_rule("substr(" + col + ",12,8)");
    if (f.kind == "decimal") {
        // Leading zero pad, 18 digit nibbles, C/D sign. Canonical positive zero.
        const auto h = "hex(" + col + ")";
        rule = "length(" + col + ")=10 AND substr(" + h + ",1,1)='0' AND substr(" + h +
               ",2,18) NOT GLOB '*[^0-9]*' AND substr(" + h + ",20,1) IN ('C','D') AND (substr(" +
               h + ",2,18)!='000000000000000000' OR substr(" + h + ",20,1)='C')";
    }
    if (f.kind == "url") {
        // An absolute URI: a nonempty ASCII scheme and no whitespace/control bytes.
        rule = "instr(" + col + ",':')>1 AND substr(" + col + ",1,1) GLOB '[A-Za-z]' AND substr(" +
               col + ",1,instr(" + col + ",':')-1) NOT GLOB '*[^A-Za-z0-9+.-]*' AND length(" +
               col + ")>instr(" + col + ",':') AND " + col +
               " NOT GLOB '*['||char(1)||'-'||char(32)||char(127)||']*' AND instr(" + col + ",char(0))=0";
    }
    return rule.empty() ? "" : " CHECK(" + col + " IS NULL OR (" + rule + "))";
}
std::string schema(const ERGraph &g) {
    std::string sql;
    for (const auto &t : g.tables) {
        sql += "CREATE TABLE user_t" + std::to_string(t.id) + "(id INTEGER PRIMARY KEY AUTOINCREMENT";
        for (const auto &f : t.fields) {
            const std::string col = "f" + num(f.id);
            std::string storage = "INTEGER";
            if (f.kind == "string" || f.kind == "url" || f.kind == "date" || f.kind == "time" ||
                f.kind == "datetime") storage = "TEXT";
            if (f.kind == "float") storage = "REAL";
            if (f.kind == "blob" || f.kind == "decimal") storage = "BLOB";
            sql += "," + col + " " + storage;
            if (!f.nullable) sql += " NOT NULL";
            if ((f.kind == "index" || !legacy(f)) && f.unique)
                sql += " UNIQUE";
            sql += field_check(f, col);
            if (!f.check.empty()) sql += " CHECK(" + f.check + ")";
            for (const auto &e : g.edges)
                if (e.table == t.id && e.field == f.id) {
                    if (!e.many)
                        sql += " UNIQUE";
                    sql += " REFERENCES user_t" + std::to_string(e.target) + "(" +
                           (e.targetField ? "f" + std::to_string(e.targetField) : "id") + ") ON DELETE " +
                           (e.cascade ? "CASCADE" : "RESTRICT");
                }
        }
        // A -> B means A has one/many B. The hidden reference belongs to B.
        for (const auto &e : g.edges)
            if (e.field == 0 && e.target == t.id) {
                sql += ",r" + num(e.id) + " INTEGER" + (e.many ? "" : " UNIQUE") +
                       " REFERENCES user_t" + num(e.table) + "(id) ON DELETE " +
                       (e.cascade ? "CASCADE" : "RESTRICT");
            }
        for (const auto &c : t.constraints)
            sql += ",CONSTRAINT " + sql_identifier(c.name) + " CHECK(" + c.expression + ")";
        sql += ") STRICT;";
        for (const auto &e : g.edges)
            if (e.field == 0 && e.target == t.id && e.many)
                sql += "CREATE INDEX user_r" + num(e.id) + " ON user_t" + num(t.id) +
                       "(r" + num(e.id) + ");";
        for (const auto &f : t.fields)
            if (f.kind == "secondary" || (f.kind == "index" && !f.unique) ||
                (!legacy(f) && f.indexed && !f.unique))
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
size_t schema_object_count(const std::string &sql) {
    size_t count = 0, start = 0;
    for (size_t i = 0; i < sql.size(); ++i)
        if (sql[i] == ';' && sqlite3_complete(sql.substr(start, i - start + 1).c_str())) {
            ++count;
            start = i + 1;
        }
    return count;
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
             "VALUES(1,'{\"version\":2,\"tables\":[],\"edges\":[]}');"
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
        require(count == schema_object_count(expected),
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
    auto s = graph_json(db, m.graph, true);
    s.pop_back();
    return s + ",\"view\":" + view_json(m) + ",\"canUndo\":" + (m.undo.empty() ? "false" : "true") +
           ",\"canRedo\":" + (m.redo.empty() ? "false" : "true") + "}";
}
void validate_er_check(const ERModel &m, int tableID, const char *expression) {
    require(expression, "Invalid CHECK expression.");
    for (const auto &t : m.graph.tables) if (t.id == tableID) {
        std::vector<std::string> columns;
        for (const auto &f : t.fields) if (!legacy(f)) columns.push_back("f" + num(f.id));
        validate_check_sql(user_check(t, expression), columns);
        return;
    }
    throw std::runtime_error("Table no longer exists.");
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
    } else if (op == "add_data_view") {
        ERDataView v{next++, j.str("name"), j.id("table"), j.number("x"), j.number("y"), {}};
        if (v.table) for (const auto &f : table(g, v.table).fields) if (!legacy(f)) v.columns.push_back({f.id, "none"});
        g.views.push_back(std::move(v));
        changesSchema = false;
    } else if (op == "update_data_view") {
        auto &v = data_view(g, j.id("id"));
        if (!j.type("name").empty()) v.name = j.str("name");
        if (!j.type("table").empty() && j.id("table") != v.table) {
            v.table = j.id("table"); v.columns.clear();
            if (v.table) for (const auto &f : table(g, v.table).fields) if (!legacy(f)) v.columns.push_back({f.id, "none"});
        }
        changesSchema = false;
    } else if (op == "set_view_column") {
        auto &v = data_view(g, j.id("id"));
        const int fieldID = j.id("field");
        require(!legacy(field(table(g, v.table), fieldID)), "Generated keys are not view columns.");
        auto it = std::find_if(v.columns.begin(), v.columns.end(), [&](const auto &c) { return c.field == fieldID; });
        if (!j.boolean("included")) {
            if (it != v.columns.end()) v.columns.erase(it);
        } else {
            const auto group = j.type("group").empty() ? "none" : j.str("group");
            if (it == v.columns.end()) v.columns.push_back({fieldID, group}); else it->group = group;
        }
        changesSchema = false;
    } else if (op == "move_data_view") {
        auto &v = data_view(g, j.id("id")); v.x = j.number("x"); v.y = j.number("y");
        changesSchema = false;
    } else if (op == "delete_data_view") {
        const int id = j.id("id"); data_view(g, id);
        g.views.erase(std::remove_if(g.views.begin(), g.views.end(), [&](const auto &v) { return v.id == id; }), g.views.end());
        changesSchema = false;
    } else if (op == "add_table") {
        g.tables.push_back({next++, j.str("name"), "#397DB8", j.number("x"), j.number("y"), {}, {}});
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
        std::vector<std::pair<std::string, std::string>> remap;
        for (auto &f : t.fields) {
            const int newID = next++;
            remap.emplace_back("f" + num(f.id), "f" + num(newID));
            f.id = newID;
        }
        for (auto &f : t.fields) f.check = rewrite_check(f.check, remap);
        for (auto &c : t.constraints) {
            c.id = next++;
            c.expression = rewrite_check(c.expression, remap);
        }
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
        g.views.erase(std::remove_if(g.views.begin(), g.views.end(), [&](const auto &v) { return v.table == id; }), g.views.end());
    } else if (op == "add_constraint") {
        auto &t = table(g, j.id("table"));
        t.constraints.push_back({next++, j.str("name"), user_check(t, j.str("expression", 4096))});
    } else if (op == "update_constraint" || op == "delete_constraint") {
        auto &t = table(g, j.id("table"));
        const int id = j.id("id");
        auto it = std::find_if(t.constraints.begin(), t.constraints.end(), [&](const auto &c) { return c.id == id; });
        require(it != t.constraints.end(), "Constraint no longer exists.");
        if (op == "delete_constraint") t.constraints.erase(it);
        else {
            if (!j.type("name").empty()) it->name = j.str("name");
            if (!j.type("expression").empty()) it->expression = user_check(t, j.str("expression", 4096));
        }
    } else if (op == "add_field") {
        ERField f{next++, j.str("name"), j.str("kind"), false};
        require(ordinary(f.kind), "Choose a standard field datatype.");
        if (!j.type("indexed").empty()) f.indexed = j.boolean("indexed");
        if (!j.type("unique").empty()) f.unique = j.boolean("unique");
        if (!j.type("nullable").empty()) f.nullable = j.boolean("nullable");
        if (!j.type("media").empty()) f.media = j.str("media");
        if (!j.type("scale").empty()) f.scale = j.id("scale");
        table(g, j.id("table")).fields.push_back(f);
        if (!j.type("check").empty()) {
            auto &t = table(g, j.id("table"));
            t.fields.back().check = user_check(t, j.str("check", 4096));
        }
    } else if (op == "update_field") {
        auto &f = field(table(g, j.id("table")), j.id("id"));
        require(!legacy(f), "Generated keys are managed through relationships.");
        const auto before = f;
        if (!j.type("name").empty()) f.name = j.str("name");
        if (!j.type("kind").empty()) {
            f.kind = j.str("kind");
            require(ordinary(f.kind), "Choose a standard field datatype.");
            if (!indexable(f.kind)) f.indexed = false;
            if (f.kind != "blob") f.media = "binary";
        }
        if (!j.type("indexed").empty()) f.indexed = j.boolean("indexed");
        if (!j.type("unique").empty()) f.unique = j.boolean("unique");
        if (!j.type("nullable").empty()) f.nullable = j.boolean("nullable");
        if (!j.type("media").empty()) f.media = j.str("media");
        if (!j.type("scale").empty()) f.scale = j.id("scale");
        if (!j.type("check").empty()) f.check = user_check(table(g, j.id("table")), j.str("check", 4096));
        changesSchema = before.kind != f.kind || before.indexed != f.indexed ||
                        before.unique != f.unique || before.nullable != f.nullable ||
                        before.media != f.media || before.scale != f.scale || before.check != f.check;
    } else if (op == "delete_field") {
        auto &t = table(g, j.id("table"));
        int id = j.id("id");
        require(!legacy(field(t, id)), "Generated keys are managed through relationships.");
        t.fields.erase(std::remove_if(t.fields.begin(), t.fields.end(),
                                      [&](const auto &f) { return f.id == id; }), t.fields.end());
        for (auto &v : g.views) if (v.table == t.id)
            v.columns.erase(std::remove_if(v.columns.begin(), v.columns.end(), [&](const auto &c) { return c.field == id; }), v.columns.end());
    } else if (op == "add_index") {
        ERField f{next++, j.str("name"), j.str("kind"), j.type("unique").empty() ? true : j.boolean("unique")};
        require(legacy(f), "Use add_field for ordinary data fields.");
        table(g, j.id("table")).fields.push_back(f);
    } else if (op == "update_index") {
        auto &f = field(table(g, j.id("table")), j.id("id"));
        require(legacy(f), "Use update_field for ordinary data fields.");
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
        require(legacy(field(t, id)), "Use delete_field for ordinary data fields.");
        t.fields.erase(std::remove_if(t.fields.begin(), t.fields.end(), [&](auto &f) { return f.id == id; }),
                       t.fields.end());
        g.edges.erase(std::remove_if(g.edges.begin(), g.edges.end(),
                                     [&](auto &e) { return e.field == id || e.targetField == id; }),
                      g.edges.end());
    } else if (op == "add_connection") {
        g.edges.push_back({next++, j.id("table"), 0, j.id("target"), 0,
                           j.type("many").empty() ? true : j.boolean("many"), false,
                           j.type("referenceName").empty() ? table(g, j.id("table")).name : j.str("referenceName"),
                           j.type("inverseName").empty() ? "" : j.str("inverseName")});
        name(g.edges.back().referenceName);
    } else if (op == "connect") {
        const int sourceTable = j.id("table"), sourceField = j.id("field");
        require(sourceField != 0, "Legacy connections require a foreign-key field.");
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
        const auto before = e;
        if (!j.type("many").empty()) e.many = j.boolean("many");
        if (!j.type("cascade").empty()) e.cascade = j.boolean("cascade");
        e.cascade = e.many && e.cascade;
        if (!j.type("referenceName").empty()) {
            e.referenceName = j.str("referenceName");
            name(e.referenceName);
        }
        if (!j.type("inverseName").empty()) e.inverseName = j.str("inverseName");
        changesSchema = e.many != before.many || e.cascade != before.cascade;
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
    bool labels = op == "update_index" || op == "update_field" || op == "update_connection" ||
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
