// SPDX-License-Identifier: Apache-2.0
#ifndef SUBCARD_CORE_H
#define SUBCARD_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns a non-null, null-terminated UTF-8 string with static lifetime.
// The caller must not modify or free it. Safe to call from any thread.
const char* subcard_greeting(void);

#ifdef __cplusplus
}
#endif

#endif
