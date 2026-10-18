# Single-selection dropdown fields

Choose **Dropdown (single selection)** from a table's **Add field** menu. The
shared C++ core creates the field, an owned `dropdown_n` table, and its fixed
1:N connection in one undoable transaction. The table contains an automatic
unique `id` and one required text column named **valued**. The field stores one
choice ID, or NULL if allowed; many records may select the same choice. SQLite
foreign keys reject IDs outside that field's own list. A lookup index is automatic.
The field's existing Allow NULL, Unique values and CHECK rules remain available.

Names use a persistent increasing counter. Deleting a field or undoing its
creation does not reuse its dropdown number. Names already occupied by an
ordinary table are skipped. Each field owns a separate list. New dropdown tables
are placed beside their owner without covering existing canvas nodes.

## Editing and ownership

Select the special canvas table to edit its **Default choices**. Add, edit,
delete and move choices up/down; every completed change supports undo/redo.
The column and table names are fixed, and the usual field/constraint editor is
replaced by this list. The canvas adds a dropdown marker and an inner border,
and omits relationship creation handles. Tables remain movable in editing mode.

Desktop uses the adjacent inspector and native document/Edit menus. SwiftUI
opens a sheet for a choice's text; GPUI uses an inline input with Apply/Cancel.
iPhone retains single-tap canvas selection and double-tap details navigation;
its choice editor uses a navigation sheet with Cancel/Apply toolbar actions.

Direct Delete, Cut, Copy and Duplicate commands are unavailable for managed
canvas tables. Their connection cannot be edited or deleted independently.
Delete the **owning field** to remove its relationship, dropdown table and
stored defaults together. Deleting the parent table also removes its owned
lists. Changing the field to another datatype removes the old list; changing
a normal field to Dropdown creates a fresh one. Undo restores the old list.
Duplicating/copying the parent table includes independent copies of its lists,
with fresh table, field, relationship and choice IDs.

Choice IDs survive renames and reordering, so existing fake selections continue
to refer to the same choices. A choice referenced by a fake record cannot be
deleted until the reference is removed or fake data is explicitly discarded.
Text may be empty or duplicated; identity is the choice ID. Text must be valid
UTF-8 without NUL and at most 4096 bytes. A list supports 10,000 choices, subject
to the existing 1 MiB graph limit.

## Defaults and lifecycle

Choices are **design defaults**, not fake/real user records. Creating or editing
them keeps global data provenance at None when no ordinary records exist,
keeps the document in editing mode, and does not latch the schema lock. Choices
can also be edited while fake records exist. Ordinary structural edits keep the
existing requirement to explicitly discard fake records first.

`subcard_system_dropdown_tables` registers each generated table's stable ID,
name and valued-column ID. `subcard_system_dropdown_values` stores each choice's
unique ID, table ID, dropdown name, text and position. The `(table_id, position)`
unique index and `(dropdown_name, position)` lookup index support ordered lookup.
The ER graph also carries the templates for atomic history and clipboard copies.
Reopen validates registry, templates, actual rows and generated schema together.

After schema replacement or fake-data discard, materialized dropdown rows are
repopulated from system defaults within the same transaction. Editing choices
updates materialized rows by ID without deleting still-used choices. Neither
materialization nor default edits pass through the user-data writer. That writer
permits selecting a choice from an ordinary record but rejects direct writes to
managed dropdown tables, even when requested as fake or real data. System defaults
survive resets; deleted lists' defaults are removed atomically.

Ordering lives in the system position column and ordered graph templates, not in
an additional visible column. Consumers must use this order rather than assume
SQLite row iteration follows insertion order.

The first real **ordinary** record still permanently locks schema definitions,
including dropdown defaults, under the existing lifecycle policy. Returning to
editing mode does not unlock a document that has held real records. Layout
changes remain available. No record-entry/card UI is introduced here.

## Command and format contract

ER metadata version **8** adds `dropdownSequence`, `kind: "dropdown"`, table
`ownerField` and ordered `values: [{id, value}]`. Existing versions 1–7 continue
to open. Files that have used dropdowns retain version 8 even after deleting the
last dropdown, preserving their counter. Older readers reject the new version.

The generated edge uses `field: 0`, the dropdown table as `table`, the owning
table as `target` and the owning field ID as `targetField`. Its cardinality is
fixed at many with no cascade. This is the exception to ordinary table edges'
`targetField: 0`: the destination field itself is the integer foreign key, so no
second hidden `r<ID>` column is generated.

- `add_field` / `update_field`: accept `kind: "dropdown"`.
- `add_dropdown_value`: `table`, `value`.
- `update_dropdown_value`: `table`, `id`, `value`.
- `delete_dropdown_value`: `table`, `id`.
- `move_dropdown_value`: `table`, `id`, zero-based destination `index`.
- `paste_table`: optional `dropdownTables` array carries owned templates alongside
  the existing `table` object. Frontends include it in table clipboard payloads.

All commands require editing mode. Defaults require an unlocked schema.
Failures roll back graph metadata, defaults, materialized rows and history.

## Verification

Backend tests cover generated columns, foreign keys and indexes, shared choices,
invalid IDs, direct-write rejection, fixed ownership, text edits/reorder with
fake references, rejected referenced deletion, reset/reseed, deletion and datatype
conversion, undo/redo, independent copies, save/reopen, monotonic naming, real-data
locking and corrupted-default rejection. SwiftUI store and GPUI tests cover the
new metadata, managed selection/command routing, copies and history.

Both macOS frontends were exercised with computer use for the dedicated pane,
choice editing and persistence; SwiftUI ordering and GPUI deletion/undo were
also checked; GPUI adding and ordering were verified after assigning stable row
identities. The unsigned arm64 physical-iPhone build passes packaging and
Mach-O iOS 16 minimum checks. Physical-iPhone interaction and Linux/Windows
runtime behavior remain untested. No simulator or new dependency was installed.
