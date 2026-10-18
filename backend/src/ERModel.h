// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "UserData.h"
#include <string>
#include <vector>

namespace subcard {
struct ERField { int id; std::string name, kind; bool unique = true; };
struct ERTable { int id; std::string name, color; double x, y; std::vector<ERField> fields; };
// field == 0: conceptual table -> target relationship; generated target.r<ID> references table.id.
// field != 0: legacy foreign-key edge, retained without rewriting existing data.
struct EREdge { int id, table, field, target, targetField; bool many = true, cascade = false; };
struct ERGraph { std::vector<ERTable> tables; std::vector<EREdge> edges; };
struct ERChange { ERGraph before, after; bool schema; };
struct ERModel {
    ERGraph graph;
    std::vector<ERChange> undo, redo;
    double zoom = 1, panX = 0, panY = 0, calibration = 1;
    int nextID = 1;
    std::string output;
    std::string content; // Canonical persistent state, excluding session history.
};
void initialize_er(sqlite3* db, ERModel& model);
std::string er_json(sqlite3* db, const ERModel& model);
// Returns false for a no-op. All writes are atomic, including generated schema.
bool er_command(sqlite3* db, ERModel& model, DocumentState& state, SubCardMode mode, const char* command);
}
