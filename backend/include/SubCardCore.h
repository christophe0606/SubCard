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
// NULL path means save to the current path. A new document needs a path.
// Save (including Save As) is a no-op while unchanged. Failure preserves edits.
int subcard_document_save(SubCardDocument* document, const char* path);

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
