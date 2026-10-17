# SQLite documents (2026-10-17)

## Implemented behavior

Both desktop frontends edit one document at a time. File > New initializes an
untitled SQLite database containing the C++ greeting. File > Open… loads an
existing `.subcard` database. A small single-line document-text field exercises
changes and persistence; it is not yet a card editor.

Save writes to the current file, or opens a native save panel for an untitled
document. Save As… chooses a new destination and leaves the original file alone.
Both commands are disabled when the current content matches the last saved (or
initial) content, including immediately after New, Open, or a successful save.
Reverting the text to its saved value also clears the changed state. A pristine
untitled document must be edited before its first Save, as required by this menu
policy. Canceling a panel or a failed save retains the document's edits and path.

New, Open, Close, and Quit ask Save / Cancel / Don't Save before replacing or
closing edited content. Saving from that prompt completes before continuing;
canceling or a save failure stops the pending operation. macOS displays the
document name and an edited window indicator.

## Shared storage and format

The C++ core owns an in-memory SQLite connection for each document. Every content
edit updates the database, not just a UI cache. Opening uses SQLite's backup API
to copy the source into that working database; editing does not silently change
the saved file. Save copies the entire working database back in a SQLite backup
transaction. This preserves additional tables and binary resources, rather than
serializing only the currently visible field. The saved document is a single
SQLite file; SubCard has no JSON or other document-data sidecar.

The version-1 database has:

```sql
PRAGMA application_id = 1396851524; -- SBCD / 0x53424344
PRAGMA user_version = 1;
CREATE TABLE document (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    text TEXT NOT NULL
) STRICT;
```

The row with `id=1` contains UTF-8 text. The core rejects unrelated databases,
unsupported versions, damaged databases, and invalid UTF-8/null-containing text.
It also refuses to overwrite an unrelated existing database. SQLite's DELETE
journal is transient during a save; no WAL or journal needs to accompany a
successfully closed document. Save errors preserve the dirty state.

SQLite 3.54.1 is vendored as unmodified amalgamation source and header, verified
against the upstream SHA3-256 archive checksum. SwiftPM and Cargo each compile
that same C source into a static library. Neither frontend links a system SQLite
library for document operations. Extension loading is omitted, threadsafety is
enabled, double-quoted SQL string literals are disabled, and temporary SQLite
storage stays in memory. See [vendor provenance](../../vendor/sqlite/README.md).

## Frontend conventions

SwiftUI uses native AppKit open/save panels, native application/window termination
confirmation, and SwiftUI File commands. Its native text field supplies the usual
Edit behavior. The shared C++ handle is owned by an object confined to the main
actor, with one release per handle.

GPUI uses native macOS File/Edit/Window menus and platform file panels. Save action
handlers exist only while changed, so GPUI's native menu validation dims Save and
Save As. Its single-line input is adapted from the Apache-licensed upstream GPUI
input example, including clipboard, selection, Unicode input, and undo/redo.
On macOS, a small Objective-C-runtime bridge routes system termination requests
through the same document-aware Quit action; other platforms do not compile it.
On Linux/Windows, the frontend also exposes an in-window File menu.

| Operation | macOS | Linux / Windows |
| --- | --- | --- |
| New / Open / Save | Command-N / O / S | Control-N / O / S |
| Save As | Command-Shift-S | Control-Shift-S |
| Close / Quit | Command-W / Q | Control-W / Q |
| Cut / Copy / Paste / Select All | Command-X / C / V / A | Control-X / C / V / A |
| Undo | Command-Z | Control-Z |
| Redo | Command-Shift-Z | Control-Shift-Z (Linux), Control-Y (Windows) |

GPUI's `secondary` modifier selects Command on macOS and Control elsewhere.
Mac-only navigation bindings stay behind a platform conditional.

## Verification and limits

`./scripts/test.sh` checks new/clean/changed/reverted states, first Save, Save As,
same-path Save, Unicode, invalid input files, unsupported versions, failed saves,
preserving the original file, and retaining extra tables and binary resources.
It also checks the direct runtime dependencies of existing macOS app builds.

On macOS, both applications were built and tested through their native menus and
panels. A SwiftUI-created document was opened and edited in GPUI, saved as another
file, and reopened in SwiftUI with the exact Unicode text. Both native File menus
were verified to disable both save commands after saving. Cancellation and
unsaved-change prompts were exercised.

All direct dynamic dependencies of the checked macOS executables resolve to
`/usr/lib` or `/System/Library`; there is no SQLite dylib, Homebrew library path,
or external SDK runtime dependency. OS frameworks may use their own system
libraries internally. Linux and Windows runtime dependencies are not yet
verified, and iOS still has its bootstrap scene rather than a document browser.

The working copy is in memory, so forced termination/power loss does not recover
unsaved edits. Saves are currently synchronous and suitable for this small
bootstrap document; large stacks will need a background-save design. Concurrent
external editing/conflict resolution, multiple document windows, recent-file
menus, card layout, and scripting are future work.
