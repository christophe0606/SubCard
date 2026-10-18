# View column builder (2026-10-18)

Views are saved query definitions over one source table. This version implements
column selection and typed aggregate choices in the shared C++ model, SwiftUI
(desktop/iPhone) and GPUI. Filtering, ordering, joins, result display and record
editing are later work. The rules for eventual writes are specified separately
in [editable query results](editable-query-results.md).

## Creating and editing

The canvas has one **Create** dropdown containing **Table**, **Connection** and
**View**. Connection requires a selected table and an unlocked schema. View
creation requires editing mode but remains available after real data locks the
table schema: a view definition never changes the underlying tables or rows.

A view appears as a purple canvas card without relationship ports. It can be
selected, moved, renamed and deleted. Fit/zoom include views. Views cannot be
connection endpoints or source tables for other views in this version.

| Desktop | iPhone |
| --- | --- |
| Selecting a view opens its properties in the resizable inspector. | Creating a view opens a separate View details page. A single tap selects its card; a double tap opens that page. |
| Standard Delete and Undo/Redo use application menus/shortcuts and focused-document state. | Standard editing commands remain in the compact Edit menu on the canvas. |
| Create is a canvas-specific dropdown. | Create is a compact canvas dropdown. |

The properties contain a view name and **Source table** dropdown, followed by two
sections of rounded column labels:

- **Selected columns**: each label has a cross that moves it to Ignored.
- **Ignored columns**: clicking the label includes it again; there is no cross or
  aggregate arrow here.

Choosing a source initially includes all its ordinary fields. Changing the source
resets selection and aggregates to that table's fields. New fields added to an
existing source appear in Ignored. Restoring an ignored column appends it to the
selected projection and resets its aggregate to None. Initial projection order
is table-field order; manual reordering is deferred.

Generated primary, foreign and legacy key fields never appear in either section.
Ordinary user fields remain visible even when Unique values is enabled: their
data and the internal row identity serve different purposes.

A view with no source or no selected columns is a saved incomplete draft. It
shows guidance and has no SQL; it never becomes a key-only query. Use mode
displays the definition with editing controls disabled.

## Aggregate menu

An eligible selected column has a small arrow on its right. Its menu always
includes **None**, the default. There is no “One” operation.

| Datatype | Choices |
| --- | --- |
| Integer, float | None, Count, Sum, Average, Minimum, Maximum |
| String, URL, date, time, date-time | None, Count, Minimum, Maximum |
| Boolean, exact packed BCD decimal | None, Count |
| Blob (including image/video/sound/document) | None only; no arrow |

The backend returns the permitted choices; neither frontend invents datatype
rules. Count counts non-NULL values. String/date/time minimum and maximum use
their stored SQLite comparison order. Packed BCD supports exact equality, but
its byte order is not numeric order and SQLite SUM/AVG do not decode it, so its
numeric aggregates are absent.

When every selected column is None, the result is an ordinary projection, with
no GROUP BY or DISTINCT. Equal visible values in separate records stay separate.

When any column uses an aggregate, selected None columns become GROUP BY
expressions. This avoids arbitrary bare-column values in SQLite aggregate
queries. With only aggregate columns, one summary row describes the whole source
table; no GROUP BY is needed. Blob columns must be ignored before aggregating;
unsupported combinations produce an explicit error and preserve the definition.

For example, Region=None and Amount=Sum generate a total per region. Returning
Amount to None restores the per-record projection. None means no aggregate on
that column; it does not request distinct values.

## Persistence and generated SQL

The `views` array is part of ER model JSON **version 6**, stored in
`subcard_system_er_model`. Versions 1–5 remain readable. Version 6 prevents older
applications from silently opening metadata they do not understand. No physical
CREATE VIEW, trigger, parser dependency or executable schema object is introduced;
the existing user-schema authorizer restrictions remain intact.

Each view stores its global object ID, name, source table ID, canvas position
and ordered selected columns (`field`, `group`). Ignored fields are derived from
the source. Live JSON also supplies `availableColumns` with backend-owned choices,
`grouped`, and `sql`. SQL is derived from validated stable IDs and allowlisted
operations, never display labels or arbitrary SQL. It is not duplicated in
persistent metadata.

An ordinary projection includes the hidden source identity:

```sql
SELECT id AS "__subcard_row_id", f2, f3 FROM user_t1
```

An aggregate query never includes that identity, even without GROUP BY:

```sql
SELECT f2, sum(f3) AS f3_sum FROM user_t1 GROUP BY f2
SELECT count(f3) AS f3_count FROM user_t1
```

Hidden identity supports future result-to-record mapping. Its inclusion does
**not** enable record editing; the analyzer and write protocol remain future
work. GROUP BY must never include that key just to retain identity, since that
would change the grouping.

View changes use atomic metadata storage, dirty tracking, snapshots and model
undo/redo. They do not rebuild tables, discard fake data, or alter data provenance
or the schema lock. Deleting a source removes dependent views in the same
undoable schema command. Deleting a field removes it from saved projections.
Renames preserve stable references. A datatype change that invalidates a chosen
aggregate is rejected until the view is adjusted. Malformed persisted references
or operations fail validation on open.

| Command | Properties |
| --- | --- |
| `add_data_view` | `name`, `table` (0 for no source), `x`, `y` |
| `update_data_view` | `id`, optional `name`, optional `table` |
| `set_view_column` | `id`, `field`, `included`; optional `group` (defaults to `none`) |
| `move_data_view` | `id`, `x`, `y` |
| `delete_data_view` | `id` |

Operations are `none`, `count`, `sum`, `avg`, `min`, `max`. Unknown values,
unsupported types, generated key selections and invalid references are rejected.
Changes require editing mode. Clipboard duplication currently applies to tables
only; view Copy/Cut/Duplicate commands remain disabled.

## Verification

- Shared-core tests execute generated SQL against sample rows and cover None
  defaults, identity omission, invalid aggregates/keys, drafts, source changes,
  save/reopen, undo/redo, dependent deletions, malformed metadata and view edits
  with fake/real data without schema replacement.
- Swift store tests cover toggles, drafts, None restoration, SQL identity,
  compact single/double-tap navigation and edits with a locked schema.
- GPUI tests use the same commands through Rust FFI and decode live metadata.
- Both macOS apps were built and exercised with computer use: Create, column
  selection/restoration, None defaults and aggregate menus. Test instances are
  quit after verification.
- The physical arm64 iPhoneOS app compiles with an artifact-verified iOS 16
  minimum. The updated development-signed build passed signature verification and
  was installed on the connected iPhone 12 Pro Max. Automatic launch was denied
  because the phone was locked. Navigation is covered by shared source/store
  tests; view interactions have not been tested on the phone. No simulator was
  installed or launched. Linux and Windows runtime behavior remains untested.
