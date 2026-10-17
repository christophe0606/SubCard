// SPDX-License-Identifier: Apache-2.0
#ifndef SUBCARD_CORE_H
#define SUBCARD_CORE_H

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
const char* subcard_last_error(void);
const char* subcard_sqlite_version(void);

#ifdef __cplusplus
}
#endif

#endif
