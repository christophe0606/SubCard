# Typed table fields

Select a table and use **Fields → Add field** in the inspector (or the details
screen on iPhone). Supported datatypes are String, URL, Date, Time, Date-time,
Binary coded decimal (BCD), Float, Integer, Boolean and Blob. Tap a field row to
expand its controls directly underneath it; tap again to
collapse them. Only one field is expanded at a time. Expansion is animated
(SwiftUI respects Reduce Motion), and the SwiftUI inspector brings the expanded
row into view. Rename it, change its datatype, configure its options or delete it
in place. iPhone name inputs have a persistent label, filled background, border,
pencil affordance and focus highlight; locked names are displayed as plain text.
The list contains ordinary data fields only; generated primary/relationship keys stay
hidden. A table supports up to 128 fields, including any legacy keys.

**Fields are never drawn on the canvas.** Table height, relationship ports,
hit testing and diagram layout are unchanged. The canvas represents tables and
their relationships only. Field selection belongs to the inspector.

Both SwiftUI and GPUI use the same C++ command and SQLite storage implementation.
Naming drafts commit on Return, focus loss, selection/model actions and document
save/replacement/close boundaries. Completed commands support undo/redo.
Copy/paste and duplicate preserve field settings while generating fresh IDs and
omitting links to other tables.

## Storage contract

Ordinary fields default to nullable and nonunique. **Allow NULL** and **Unique
values** are independent rules in each expanded field's controls on desktop and
the iPhone table-details screen. Turning off Allow NULL generates `NOT NULL`;
turning on Unique values generates `UNIQUE`. Both are enforced by SQLite for
inserts and updates, including direct SQL writes. NULL means no value, not empty
text: a required string can still contain `''`. A nullable unique field permits
multiple NULLs but rejects duplicate non-NULL values. An optional custom CHECK
expression per field and multiple named table CHECKs are also available; see the
[CHECK constraint editor](check-constraints.md). The datatype checks below remain automatic.

Physical column names are stable `f<ID>` values;
renaming a field changes its label without rewriting or discarding rows.
SQLite STRICT tables enforce the underlying storage classes and CHECK constraints
enforce the additional formats below. This applies to writes through the shared
core, not just to frontend controls.

| Datatype (`kind`) | SQLite storage | Value representation | Optional index |
| --- | --- | --- | --- |
| String (`string`) | TEXT | Unicode text | Yes |
| URL (`url`) | TEXT | Absolute URI with an ASCII scheme and nonempty remainder, no ASCII whitespace/control characters or NUL | Yes |
| Date (`date`) | TEXT | Valid Gregorian `YYYY-MM-DD` | Yes |
| Time (`time`) | TEXT | `HH:MM:SS`, 00:00:00–23:59:59 | Yes |
| Date-time (`datetime`) | TEXT | UTC `YYYY-MM-DDTHH:MM:SSZ` | Yes |
| Binary coded decimal (`decimal`) | BLOB | Exact signed 18-digit coefficient and field-level scale 0–18 | No |
| Float (`float`) | REAL | SQLite double precision floating point | Yes |
| Integer (`integer`) | INTEGER | Signed 64-bit integer | Yes |
| Boolean (`boolean`) | INTEGER | 0 or 1 | Yes |
| Blob (`blob`) | BLOB | Arbitrary bytes, including embedded zeros | No |

Dates reject impossible/leap-day dates; times reject 24-hour values and leap
seconds. Temporal values have second resolution; UTC normalization belongs to
the future record editor. Canonical date/time text sorts chronologically.
URL validation checks the generic absolute-URI form, including `https:` and
`mailto:`; it does not check scheme-specific host rules or network reachability.
URL fields do not automatically open or fetch anything.

**Indexed** creates an optional normal SQLite index for suitable datatypes.
**Unique values** is available for every datatype independently of this option;
SQLite automatically creates its unique index. For indexable types the Indexed
control shows on and is disabled while uniqueness is enabled. Turning uniqueness
off restores the separately stored optional-index preference. Changing datatype
or the optional-index preference never clears uniqueness or nullability.
String/URL indexes use SQLite's default case-sensitive BINARY
collation. Boolean indexes are available when useful despite their small value
range. Blob and packed BCD fields do not offer an optional lookup index: ordinary
BLOB byte order is not signed decimal numeric order. They do support uniqueness:
blobs compare exact bytes, and canonical BCD compares exact values at the field's
fixed scale. Changing to one of these types clears only the optional lookup index.
Relationship indexes remain automatic and
independent of these options.

### Packed BCD

BCD never passes through a binary float. The ten stored bytes contain a leading
zero pad nibble, eighteen decimal-digit nibbles (most significant first), then a
sign nibble: C for nonnegative and D for negative. Zero must use C. At scale 2,
`123.45` is coefficient 12345 and bytes `0000000000000012345C`; negative values use
a final D. The decimal value is the signed coefficient divided by 10^scale.
The absolute coefficient is at most 999999999999999999. The default scale is 2;
**Decimal places** changes it from 0 to 18 before real data locks the schema.
SQLite rejects wrong lengths, nondigit nibbles, invalid sign/pad nibbles and
negative zero. Numeric arithmetic/ordering and record-entry conversion are future
shared-core work; a BLOB comparison must not be used as a decimal range query.

### Blob purposes

Blob **Content** can be Binary data (`binary`, default), Image (`image`), Video
(`video`), Sound (`sound`) or Document (`document`). For an address book, add a
Blob called Photo and choose Image. Its bytes live inside the `.subcard` SQLite
stack, so saving/copying a stack preserves them without external file paths.
The purpose is a presentation hint; it does not transcode or inspect the bytes.
Filename/MIME metadata, file import, record-value editing, thumbnails and media
playback belong to the future card editor. This feature implements schema design
and persistent typed storage, not a record-entry or attachment viewer UI.

## Commands and compatibility

Documents containing custom CHECKs use ER model version **5**. Documents with
required fields or uniqueness independent of an optional index
serialize ER model version **4**. Other ordinary typed fields retain version **3**;
models containing only earlier keys/relationships retain version 2. Versions 1–3
remain readable without rebuilding tables or rewriting real data. Missing
`nullable` metadata defaults to true. Applications supporting only versions 1–3
reject version 4, protecting rules they cannot interpret. Document-container
version remains unchanged.

- `add_field`: `table`, `name`, `kind`; optional `indexed` (false), `unique`
  (false), `nullable` (true), `media` (binary), `scale` (2), `check` (empty).
- `update_field`: `table`, `id`; optional `name`, `kind`, `indexed`, `unique`, `nullable`,
  `media`, `scale`, `check`. Omitted options are preserved. Leaving Blob resets its media
  purpose to binary; changing to Blob/BCD clears only optional indexing.
- `delete_field`: `table`, `id`.

All IDs share the graph's global ID namespace. Names are validated centrally and
must be unique within their table, including the implicit id name. Invalid
commands are atomic and consume no IDs/history. Legacy `add_index`,
`update_index`, `delete_index` and `connect` remain compatibility commands for
legacy keys only; ordinary fields never become relationship destinations.

Field commands require editing mode. Adding/deleting fields, changing a type,
index, uniqueness, nullability, scale or blob purpose requires an unlocked schema
and explicit discard of any fake data first. Name-only edits preserve fake rows. Once any real
data has existed, field labels and definitions are locked as well. Layout and
color edits continue under the existing lifecycle rules. No schema migration is
introduced.

## Verification

Field-rule coverage exercises required and unique values across all ten datatypes,
nullable unique fields with multiple NULLs, rejected inserts/updates and atomic
rollback, direct SQLite writes, undo/redo, copy/paste, schema locks and reopening
older typed documents without changing their rows or schema. SwiftUI store and
GPUI model tests cover the field-rule metadata. Both macOS inspectors were checked
with computer use, including enabling both rules and the automatic index state;
SwiftUI Undo was also checked. Temporary test apps were quit afterward. iPhone
validation is compilation for a physical iPhone, with the packaged iOS 16 minimum
verified; the new controls have not been tested on a physical iPhone. Project
policy prohibits installing or running iPhone/iOS simulators.

`./scripts/test.sh` exercises every storage class, valid/null values, invalid
calendar/time/URL/BCD/boolean values, embedded NUL rejection for temporal/URL
values, uniqueness, actual query-planner index use, datatype/index changes,
copy ID remapping, fake-data protection, real-data locks, undo/redo and save/reopen.
Binary payloads with zero bytes survive saves and reopening. The SwiftUI store
suite checks field draft ownership, lifecycle commits, stale-property actions,
selection after deletion, metadata duplication and constant canvas height.
GPUI tests check field JSON compatibility, options and constant canvas height
alongside the existing relationship/viewport tests.

Both Mac apps and the unsigned arm64 iPhone app build; iPhone verification confirms
an iOS 16.0 packaged/Mach-O minimum. Native Mac checks cover the SwiftUI Add field
menu, URL rename/index/unique controls, image purpose selection, GPUI opening the
same stack, rename/media/undo/BCD scale controls and GPUI saves. Saved metadata
confirms the cross-frontend edits. Physical iPhone interaction and Linux/Windows
runtime checks were not performed. No new dependency was introduced. Build,
cache and verification files remain under `.build/` on the external volume.

### Inline field editor refinement

Field controls now sit within the selected row, ahead of the next field. A
disclosure chevron shows expansion; tapping again collapses it. SwiftUI animates
expansion/collapse over 0.22 seconds and keeps the selected row visible. Reduce
Motion disables the transition. GPUI inserts the same controls inline with a
short fade. Selecting/collapsing rows is transient and creates no model undo step.

The iPhone name controls have persistent labels, a filled background, a visible
border and a pencil icon, with an accent border while focused. Locked names use
plain read-only text. Field-name drafts still commit before switching/collapsing.

Verification: both Mac builds, existing backend/Swift editor suites and all five
GPUI tests pass. Native Mac checks confirm inline ordering, disclosure controls
and SwiftUI name commits while switching/collapsing. The revised app was built,
development-signed, verified for iOS 16 and installed on the paired iPhone with
`--no-launch` for the user's touch/layout acceptance test. No document format or
canvas rendering change was needed for this refinement.
