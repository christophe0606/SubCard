# Custom CHECK constraints

Each ordinary field has one optional CHECK expression. Each table has a list of
up to 32 named CHECK constraints. Every field and table CHECK must pass when a row
is inserted or updated. Existing datatype, nullability and uniqueness rules still
apply. CHECK evaluates the SQLite expression: zero rejects a row, while nonzero
or NULL accepts it. Use **Allow NULL** separately to require a value.

## Editing

Expand a field and choose **Add CHECK expression**, or use **Add named constraint**
under **Table CHECK constraints**. Enter only an expression, without `CHECK(...)`:

```sql
"Age" BETWEEN 0 AND 150
```

A named table rule can compare several fields in the same row:

```sql
"End date" >= "Start date"
```

Use the field names shown in the editor. Double quotes quote identifiers; single
quotes delimit string literals. A double quote inside a field name is escaped by
doubling it. The editor lists the table's available field names. `id` is also
available. SQLite keywords used as field names must be quoted.

Both frontends display validation errors and disable **Apply** while the
expression is invalid. Named rules also require a nonempty, distinct name within
their table. Choose an existing rule to edit it. Click the **cross inside a disk**
beside a rule to delete it. Deletion supports Undo; no confirmation dialog is
needed for this reversible schema edit. Cancel discards an unaccepted draft.

On macOS, SwiftUI uses a sheet with Cancel/Apply and standard text editing.
GPUI expands a compact inline editor in the inspector. On iPhone, the editor is
a native navigation sheet with a scrollable form and Cancel/Apply navigation
controls that remain accessible with the keyboard. SwiftUI's SQL input uses
native plain text with smart quotes, smart dashes and spelling checks disabled;
macOS uses TextKit 1 to avoid the text-checking stall found during UI testing.

## Validation and storage

The shared C++ core compiles an actual SQLite `CREATE TABLE ... CHECK(...)` on a
disposable **in-memory** database. It does not evaluate the expression or modify
document data, dirty state, history or IDs. This validates syntax, column names,
available functions and SQLite's CHECK restrictions (including no subqueries,
aggregate or window functions). An expression is limited to 4096 UTF-8 bytes.
SQL statements, comments and bind parameters are rejected. Semicolons/comment-like
text inside string literals are preserved.

The restricted SQL boundary permits the built-in scalar functions listed by
`allowed_user_function` in `CheckExpression.cpp`, including `length`, `trim`,
`lower`, `upper`, `replace`, `substr`, `instr`, `abs`, `round`, `coalesce`, `typeof`,
`like`, `glob` and the date/time functions. Unknown or unapproved functions are
rejected. Syntax validation does not prove that a rule is true for any particular
row, or that every possible argument avoids a runtime function error.

A token-aware identifier rewrite translates visible field names to stable SQLite
columns (`f<ID>`). String literals and function calls remain intact. Persisted
expressions use those stable IDs; the live editor JSON also supplies an expression
rendered with current field labels. Consequently a field rename preserves a rule,
and duplicate/paste remaps references and constraint IDs to the copied table.
Deleting a referenced field is rejected until the referencing rule is removed or
edited. No field or table constraint is silently dropped.

SQLite enforces the resulting CHECKs, including writes outside the UI. Rule
creation, edits and deletion require editing mode, an unlocked schema and explicit
discard of fake data first. A document that has held real data keeps its existing
schema lock. There is no data migration in this feature.

## Model and command contract

Documents containing custom CHECKs use ER model **version 5**. Versions 1–4 remain
readable with no custom constraints by default and no schema rewrite. Older
applications reject version 5. The document-container version is unchanged.

- `add_field` / `update_field`: optional `check` expression using visible field
  names. Omission preserves an existing rule; `""` removes a field rule.
- `add_constraint`: `table`, `name`, `expression`.
- `update_constraint`: `table`, `id`; optional `name`, `expression`.
- `delete_constraint`: `table`, `id`.
- `subcard_document_validate_check(document, table, expression)`: read-only C API
  for frontend previews, returning 1 when valid or 0 plus `subcard_last_error()`.
  The command boundary validates again before accepting any mutation.

Fields serialize canonical SQL in `check`; live JSON adds `checkDisplay`.
Tables serialize `constraints`, each with `id`, `name` and canonical `expression`;
live JSON adds `displayExpression`. Missing properties default to no custom rule.
Constraint IDs share the graph's global namespace and participate in history.

## Verification

The backend suite checks syntax errors, unknown columns/functions, injection
attempts, parameters, subqueries, aggregate/window misuse, multiple named rules,
NULL behavior, actual rejected inserts/updates and batch rollback, persistence,
quoted literals, stable renames, copied IDs, deletion, undo/redo and schema locks.
SwiftUI store and GPUI tests use the actual shared C API to preview and accept
rules and round-trip their metadata.

Desktop computer-use checks verified invalid/valid expression feedback and
disabled/enabled Apply in both frontends, multiple named rules and a field rule
in SwiftUI, circled-cross deletion in both frontends, and restoration with Undo
in SwiftUI. The macOS text-checking hang was reproduced and resolved with the
native plain-text editor. All temporary app instances were closed after testing.

iPhone validation uses the physical-device build and verifies the packaged iOS 16
minimum. No iOS simulator is installed or run; physical-device UI testing remains
outstanding.
