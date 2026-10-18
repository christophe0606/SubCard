// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "SubCardCore.h"
struct sqlite3;

namespace subcard {
struct DocumentState {
    SubCardDataKind data_kind = SUBCARD_DATA_NONE;
    bool schema_locked = false;
};
// System storage defaults can be added to an old bootstrap document without
// interpreting or migrating any user schema. All user writes go through here.
void reset_dropdown_rows(sqlite3* db);
void initialize_document_state(sqlite3* db);
DocumentState read_document_state(sqlite3* db);
DocumentState replace_user_schema(sqlite3* db, DocumentState state, SubCardMode mode, const char* sql);
DocumentState write_user_data(sqlite3* db, DocumentState state, SubCardMode mode,
                              SubCardDataKind kind, const char* sql);
DocumentState discard_fake_data(sqlite3* db, DocumentState state, SubCardMode mode);
}
