// SPDX-License-Identifier: Apache-2.0
#ifndef SUBCARD_CORE_H
#define SUBCARD_CORE_H
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns a non-null, null-terminated UTF-8 string with static lifetime.
// The caller must not modify or free it. Safe to call from any thread.
const char* subcard_greeting(void);

// Document handles are owned by the caller and confined to one UI thread.
// All strings are UTF-8. Borrowed strings remain valid until the next mutation
// of their document. No C++ exception crosses this API. Failure returns NULL/0;
// subcard_last_error() returns the current thread's error until its next call.
typedef struct SubCardDocument SubCardDocument;
SubCardDocument* subcard_document_new(void);
SubCardDocument* subcard_document_open(const char* path);
void subcard_document_close(SubCardDocument* document);
const char* subcard_document_text(const SubCardDocument* document);
const char* subcard_document_path(const SubCardDocument* document);
int subcard_document_is_changed(const SubCardDocument* document);
int subcard_document_set_text(SubCardDocument* document, const char* text);

// Data provenance is GLOBAL across ALL user tables, never per table or row.
// Persistent provenance and schema lock are independent of session mode.
typedef enum SubCardDataKind {
    SUBCARD_DATA_NONE = 0, SUBCARD_DATA_FAKE = 1, SUBCARD_DATA_REAL = 2
} SubCardDataKind;
typedef enum SubCardMode {
    SUBCARD_MODE_EDIT = 0, SUBCARD_MODE_USE = 1
} SubCardMode;
SubCardDataKind subcard_document_data_kind(const SubCardDocument* document);
SubCardMode subcard_document_mode(const SubCardDocument* document);
int subcard_document_schema_is_locked(const SubCardDocument* document);
// Switching modes is transient, never unlocks the schema or marks a file changed.
int subcard_document_set_mode(SubCardDocument* document, SubCardMode mode);
// Storage primitives for a future ER editor/data layer, not end-user SQL tools.
// Replace the complete user schema in editing mode. Only CREATE TABLE/INDEX in
// the user_ namespace is supported. Empty SQL clears it. Fake rows are discarded
// atomically; a document that has ever held real rows rejects all replacements.
int subcard_document_replace_user_schema(SubCardDocument* document, const char* sql);
// A batch of INSERT/UPDATE/DELETE statements on user_ tables. kind must be FAKE
// or REAL. Existing fake/real rows cannot be mixed or relabeled. Fake writes
// require editing mode and an unlocked schema. First real rows lock the schema.
// Deleting the last row yields NONE but retains any historical schema lock.
int subcard_document_write_user_data(SubCardDocument* document, SubCardDataKind kind, const char* sql);
// Explicitly discard fake data before entering real data. Never deletes real rows.
int subcard_document_discard_fake_data(SubCardDocument* document);
// NULL path means save to the current path. A new document needs a path.
// Save (including Save As) is a no-op while unchanged. Failure preserves edits.
int subcard_document_save(SubCardDocument* document, const char* path);

// ER graph/viewport JSON: version 8 with managed dropdowns, 7 with named relationships, 6 with data views, 5 with custom CHECKs,
// 4 with field rules, 3 with typed fields, otherwise 2. Opens versions 1-8.
// Borrowed until next call/mutation.
// Command API is shared by frontends and future scripting adapters. See the ER
// architecture document for the command contract. View changes skip undo history.
const char* subcard_document_er_json(SubCardDocument* document);
int subcard_document_er_command(SubCardDocument* document, const char* command);
// Validate a scalar CHECK expression using visible field names, without writing
// data or history. Returns 1 if valid, otherwise 0 and subcard_last_error().
int subcard_document_validate_check(const SubCardDocument* document, int table, const char* expression);

// Immutable, owned full-database snapshot for platform-managed file writers.
// Taking/canceling a snapshot does not change the document's path or dirty state.
typedef struct SubCardSnapshot SubCardSnapshot;
SubCardSnapshot* subcard_document_snapshot(const SubCardDocument* document);
const void* subcard_snapshot_bytes(const SubCardSnapshot* snapshot);
size_t subcard_snapshot_size(const SubCardSnapshot* snapshot);
void subcard_snapshot_close(SubCardSnapshot* snapshot);
// Call only AFTER the platform successfully writes this snapshot. Edits made
// since the snapshot remain changed. A snapshot belongs to its original document.
int subcard_document_accept_snapshot(SubCardDocument* document,
    const SubCardSnapshot* snapshot, const char* path);
const char* subcard_last_error(void);
const char* subcard_sqlite_version(void);

#ifdef __cplusplus
}
#endif

#endif
