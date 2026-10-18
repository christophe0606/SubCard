# Entity relationship canvas

## Original implementation plan and acceptance checks (historical)

1. [x] Add a shared, versioned ER model and a validated JSON command boundary in C++.
   Generate SQLite user tables, indexed fields and foreign keys from it.
2. [x] Persist model/layout and viewport in application-owned system tables. Keep
   model commands undoable; keep navigation out of history. Preserve schema locks.
3. [x] Implement the SwiftUI Mac/iPhone canvas and inspectors; implement the GPUI
   desktop canvas against the same commands. Use native clipboard support.
4. [x] Test commands, generated constraints, rollback, history, locks, save/reopen,
   snapshots and viewport independence. Build both Mac apps and the iOS 16 app.
   Exercise canvas interactions on both Mac frontends and record results below.

## Architecture and decisions

The C++ document owns the graph and command history. Frontends send JSON commands
through `subcard_document_er_command` and read a versioned JSON snapshot through
`subcard_document_er_json`. A future Lua adapter can invoke precisely this API;
it must not manipulate SQLite or frontend state. No scripting runtime is added.
Commands validate references, names, numeric ranges and mode/lock restrictions
before applying any change. Errors use the existing C API error channel.

`subcard_system_er_model` stores the versioned graph including stable IDs, table
positions and colors. `subcard_system_er_view` stores zoom, pan and scale calibration.
Both are included in document backups and platform file snapshots. Old greeting
only documents acquire defaults in memory. No automatic interpretation of legacy
raw SQL schemas is attempted: replacing an existing non-ER schema is rejected.

## Table relationships (2026-10-18)

The current editor exposes tables and arrows. An arrow **A → B** means **A has
one B (1:1)** or **A has many B (1:N)**. The arrow direction describes the user's
model. It does not describe the direction of a SQL reference.

Create an arrow by dragging a table's right circle onto another table (including
its left circle), or select a table, choose **Relationship** on the canvas toolbar,
and click/tap the destination. Tapping the right circle also arms the source for
a subsequent destination tap, including on iPhone. Cancel abandons the pending
arrow without creating a field or consuming an undo step. New arrows default
to 1:N and are selected after creation. Select the line or cardinality label to
change between 1:1 and 1:N in the inspector. Switching cardinality keeps the same
arrow ID, direction and endpoints. Both choices remain editable throughout schema
design, subject to the existing schema lock and fake-data protections below.

Table cards display names and table-level relationship handles. The current UI
contains no key fields, field-key ports, index editor, Unique toggle or SQL key
names. Indexes on ordinary data fields remain future work. Parallel relationships
have separate routes, and self references and cycles remain supported.

### Relationship role names

The connection edit panel in SwiftUI (macOS and iPhone) and GPUI provides:

- **Reference name**: the field name in the destination table B, for both 1:N
  and 1:1. For example, Colors → Products can name this reference **Color**.
  New relationships initially use the source table's name; edit it to describe
  the role. Explicit reference names must contain 1–128 UTF-8 bytes, without
  control characters or whitespace-only values.
- **Inverse name (optional)**: the reverse role in the source table A. For
  People → Passports, the reference might be **Holder** and the inverse
  **Passport**. Clear the inverse name to omit it. Nonempty inverse names use
  the same validation as reference names.

The canvas displays the reference near the **destination** endpoint. For **1:N**
this is the only role name shown. For **1:1**, a nonempty inverse name also appears
near the **source** endpoint. The reference is still physically stored in B;
showing both roles does not create a second reference column. Switching
cardinality retains both names, including the inverse hidden by a 1:N arrow.

Names use measured, single-line text with ellipsis for long labels; the full
value remains editable in the panel. Placement reserves clearance from every
table/view card and previously placed role label, moving above obstacles when
tables are close, reversed or connected to themselves. Label rectangles take
zoom/calibration into account and are clickable to select the connection.
Cardinality is centered at half the full routed arrow length, including straight
arrows with a zero-length middle segment and bent/self routes. Its measured
bounds are reserved when placing endpoint names, so role labels cannot cover
the 1:N or 1:1 text. Label placement does not move tables. Fit includes role labels.

Both names participate in document save/reopen and undo/redo. Drafts commit on
Return, focus/selection changes and document lifecycle actions, just like table
names. They are schema labels: naming is disabled after real data locks the
schema. Name-only changes preserve fake rows and stable SQL keys without DDL.
These names prepare future relationship selectors; they do not yet implement
dropdowns, radio groups, choice-label columns or data-entry controls. Role names
are not currently required to be unique within a table.

Named relationships use graph metadata **version 7**, including when combined
with views. Versions 1–6 remain readable; absent names decode as empty and leave
existing physical columns intact. Legacy field edges use their conceptual
direction (reference at the child/destination, inverse at the parent/source).
An old unnamed relationship can be named in the panel. Older SubCard versions
reject version 7 rather than silently losing the names.

Validation on 2026-10-18 covers C++ name persistence/validation, partial updates,
undo/redo, old unnamed metadata, stable references and fake-row preservation;
SwiftUI draft ownership and commit behavior; and Swift/GPUI label clearance and
whole-path midpoint geometry. Both macOS apps were built and checked with the
native UI. The iPhoneOS app was compiled, signed, installed and launched on the
user's physical iPhone; device interaction testing is being performed by the user.

### Arrowhead zoom and iPhone table placement

Connection arrowheads use model-space geometry in SwiftUI and GPUI, so their
length and width scale with zoom and display calibration just like the table
ports. An arrow's tip stops outside the destination circle, with a one-unit
gap beyond its six-unit radius; the circle cannot hide the arrowhead at high
zoom. A connection preview ends at the pointer, since it has no target port yet.

On iPhone, Add Table places the new table **below** the selected table in a
portrait canvas and **to its right** in landscape. With no table selected, the
most recently created table is the anchor. Occupied positions are skipped in
that direction, including view cards. The first table starts near the current
viewport; rotation affects subsequent insertions without rearranging existing
tables. Desktop placement retains its existing layout. The new table remains
selected on the canvas, and the existing animated reveal preserves zoom and
adds no undo step beyond the table creation itself.

Swift geometry tests cover port clearance across zoom/calibration, and editor
tests exercise portrait/landscape placement, rotation, occupied slots, selection
and undo/redo. Physical-iPhone builds are used for validation; no simulator is
installed or run.

Physical SQL names use stable IDs independently of editable labels. Every table
has a hidden `id INTEGER PRIMARY KEY AUTOINCREMENT`. A new relationship with ID E
from A to B generates a hidden nullable `r<E> INTEGER REFERENCES user_t<A>(id)`
column in **B**. For 1:N, the backend generates `user_r<E>` on that column. For
1:1, `UNIQUE` supplies both enforcement and an SQLite index; a redundant secondary
index is unnecessary. The parent primary key is indexed by SQLite. Regression
checks inspect the query plan to verify indexed access on both sides of a join.

Keys are optional references: 1:1 means at most one matching B for each A, and
multiple unassigned B rows may have NULL references. Mandatory participation is
not a separate editor concept in this version. Deletion blocks by default; the
1:N cascade option deletes related B rows when their A row is deleted. Removing
an arrow removes its generated key and index. Undo restores the entire change.
Duplicating/copying a table does not copy its relationships or generated keys.

### Existing documents and versioning

Conceptual table arrows use at least **version 2** metadata; role names require
**version 7** as described above. The loader accepts versions 1–7, including the
intermediate typed-field, constraint and view formats. Version 2 prevents older
binaries from silently interpreting table arrows as field-based foreign keys.

Existing field-based keys, indexes, constraints and rows are preserved. Their
metadata still uses `index` / `secondary` field kinds and nonzero edge `field`
IDs. Both frontends hide these fields and display each legacy arrow in the
conceptual direction: its referenced table → its referencing table. This only
changes presentation; opening or cosmetically editing an old document never
reverses a stored foreign key or rebuilds real data. Legacy commands remain at
the backend boundary for compatibility, without UI controls. Editing an old
arrow's cardinality continues to apply to its existing physical key.

New arrows have `field: 0`, `targetField: 0`, `table: A`, and `target: B` in the
shared graph; these markers distinguish them from legacy edges. Generated keys
are derived directly from edges and never added to the graph's field list.

Editing a schema requires edit mode and an unlocked document. Existing fake data
must be explicitly discarded before schema commands, avoiding silent data loss.
Layout/color edits do not rebuild tables and remain possible for locked schemas
in edit mode. Commands cannot unlock a schema. Raw schema/data writes invalidate
ER undo history; undo never restores historical database images over real data.

History consists of before/after graph values and whether SQL schema changed.
The last 200 model commands are undoable within the session; history is not saved.
Canonical persistent state is compared with the saved snapshot, so undoing back
to the saved model clears the edited indicator (unless navigation or data changed).
One completed drag is one command. Viewport changes persist and dirty the file
but neither create nor invalidate redo. Selection and pending connections are
transient. Copy/paste uses a versioned table JSON payload, remaps IDs and copies
fields without links to other tables. Duplicate uses the same copy semantics.

100% uses 72/2.54 logical points per centimetre for title font em size. Font glyph
ink is font dependent. Displays/platform scaling do not guarantee physical
centimetres; a persisted calibration factor adjusts the measured 100% size.
Zoom is bounded to 0.01–400%, so Fit also handles widely separated tables.
Canvas coordinates are independent of zoom. Fit computes table bounds with padding. Scrollbars mirror pan; dragging background
pans. On Mac an adjustable divider separates the inspector. On iPhone selection
opens a separate detail screen and returns to the canvas without losing layout.

## iPhone interaction refinements

Adding, pasting or duplicating a table selects it on the canvas without pushing
its details screen. On iPhone, a single tap selects a table and a double tap opens
its details. On desktop, a single click selects it and updates the adjacent
inspector. Tapping an arrow opens its relationship details.
**Table** also reveals the newly created table by panning the canvas at the current
zoom and calibration. The entire table is brought inside a 24-point margin when
it fits; at larger scales the leading edge/header remains visible. The actual
canvas dimensions exclude the inspector and toolbar, with space reserved for
scrollbars that may appear. The reveal is saved as viewport state and adds no
undo step: one Undo removes the newly created table. Both Mac frontends and
iPhone use this behavior, including the Mac Add Table shortcut.

The compact iPhone toolbar uses a prominent **Table** button and bordered **Zoom**
and **Edit** (ellipsis) menus. Zoom contains Fit to Window and 25%, 50%, 75%, 100%, 125%,
150%, 175% and 200%. Edit groups Undo/Redo, Copy/Cut/Paste, Duplicate and Delete,
with availability based on selection, mode and schema lock. Cut copies first and
then submits one undoable delete command; it does not delete if copying fails.

On iOS 16, `ERCanvasTouchInput` uses native UIKit touches and a pinch recognizer
because SwiftUI's older magnification gesture does not report its touch anchor.
The first two touch positions establish the initial midpoint. Pinching cancels
any provisional single-finger table move, and the remaining finger cannot start
a drag until the gesture has lifted. Each update uses the original viewport and
initial midpoint rather than accumulating scale or following the screen center.

`ERViewport.zoomed` preserves the projected world point with
`pan' = pan + anchor / oldScale - anchor / newScale`, including display calibration.
Viewport pan is signed (bounded to +/- 1 billion world units): clamping at zero
would shift an off-center pinch anchor when zooming out. Table coordinates keep
their existing bounds. Signed camera offsets remain persistent UI state and do
not create undo entries; both frontends can reopen them.

The refinement build passes both desktop builds, the iOS 16 build and the full
backend/viewport regression suite. It was development-signed and installed on the
connected iPhone. Automatic launch was blocked by the device lock; the user chose
to open SubCard manually for the next physical interaction test.

## Previous field editor refinement (historical; superseded by table relationships)

1. [x] Replace separate creation/rename/connect forms with one selectable field
   list and an extensible **Add field** menu (Index / Connection). Keep the
   auto increment primary key implicit rather than listing it as a field.
2. [x] Commit table/field names on Return, focus loss, selection change, other
   model actions and leaving details. Update the committed-name heading immediately.
   Remove explicit Rename buttons. Flush drafts before document save, replacement,
   close and mode change; include pending drafts in the Save/dirty UI.
3. [x] Add **Connection** to the canvas toolbar, targeting the selected table
   and selecting the new unconnected field. Highlight selected fields and arrows.
   Drag from a connection row or its right port to a primary-key header/port or
   a unique index row/left port. Display the resolved table/key read-only in details.
4. [x] Expose **Unique** on selected indexes in both frontends. Enforce destination
   uniqueness in C++, persist it, preserve existing files, and support undo/redo.
5. [x] Add regression coverage for draft ownership, color actions after typing,
   arrow selection/deletion, uniqueness enforcement and persistence; build both
   Mac frontends and iPhone, check native Mac interactions, install on iPhone.

`ERStore.swift` separates SwiftUI editor state/draft ownership from canvas and
inspector presentation. The document owner registers a weak editor commit hook,
invokes it before lifecycle operations, and detaches the raw C handle before it
is released. GPUI owns analogous draft baselines and subscribes to native focus
loss and Return events. Each completed rename is one core command; typing remains
local until committed. Undo refreshes both the heading and text control.

The shared command boundary remains the single model mutation path for both
frontends and the future scripting adapter. `connect` creates an arrow for an
unbound field or retargets its existing arrow while preserving stable ID,
cardinality and deletion policy. A rejected edit is atomic and consumes no history.
Unique changes are schema operations, so fake-data and real-data protections apply.
Name-only edits keep stable physical SQL names and do not rebuild tables.

## Command contract (version 2; version 1 remains readable)

Commands have an `op` string and relevant properties. IDs are positive integers;
`targetField: 0` means the header primary key. Commands:
`add_table` (name,x,y), `update_table` (id,name,color), `move_table` (id,x,y),
`delete_table` (id), `paste_table` (table),
`add_connection` (table,target,many?; defaults to 1:N),
`update_connection` (id,many,cascade), `delete_connection` (id),
`undo`, `redo`, and `view` (zoom,panX,panY,calibration).
Legacy compatibility commands: `add_index` (table,name,kind,unique?),
`update_index` (table,id,name,unique?), `delete_index` (table,id),
`connect` (table,field,target,targetField).
Legacy kinds are `index` and `secondary`; neither is displayed in the current UI. `unique` is
boolean, defaults to true for omitted properties in older files/creation commands,
and can only be changed for indexes. A name-only update preserves uniqueness.
Graph field and edge IDs are globally unique.
View defaults: zoom=1, panX=0, panY=0, calibration=1.

## Add Table visibility regression checks

The viewport suites in Swift and Rust cover phone/desktop sizes, zoom and display
calibration limits, negative pan, distant tables and models near coordinate bounds.
They assert full visibility when a table fits, header/leading-edge visibility when
it does not, unchanged zoom, and no panning for an already visible table. The real
SwiftUI store test creates repeated tables at several zoom levels and verifies
that each creation selects/reveals the new table without opening details, and
that one Undo removes it while preserving the camera.

This fix passes `./scripts/test.sh`, the GPUI viewport unit tests
(`cargo test --locked --manifest-path apps/gpui/Cargo.toml viewport_tests`, after
sourcing `scripts/environment.sh`), both Mac builds, and the signed iOS 16 build.
A native SwiftUI check at 200% with a narrow canvas confirms repeated Add Table
actions follow the newest table and leave its header visible. The update was
installed on the connected iPhone with `--no-launch` for the user's manual test.

## Earlier verification results (before table-only relationships)

Verified on macOS on 2026-10-18:

- `./scripts/test.sh`: existing document/lifecycle suites and the new
  `tests/er_model_tests.cpp` suite pass with `-Wall -Wextra -Werror`.
- ER tests exercise Unicode and invalid JSON/names/ranges, generated
  AUTOINCREMENT keys, unique indexed targets, foreign-key rejection, 1:1
  uniqueness, 1:N cascade/block deletion, self references, dependent connection
  removal/restoration, copy ID remapping, layout/color persistence, schema locks,
  explicit fake-data protection, branching undo/redo, saved-state comparison,
  independent viewport history, snapshots, and corrupt metadata/schema rejection.
- `tests/er_viewport_tests.swift` checks the screen-position invariant across
  off-center anchors, zoom limits, calibration factors and positive/negative pan,
  as well as zoom round trips and signed viewport serialization. Backend tests
  also verify signed/large viewport offsets save and reopen without undo entries.
- Field-refinement regressions: unconnected foreign-key fields, normal indexes
  accepting duplicate values, UNIQUE rejecting them atomically, invalid destinations,
  referenced-index protection, uniqueness undo/redo/save/reopen, compatibility with
  metadata predating `unique`, and retargeting an arrow without changing its ID.
- `tests/er_editor_tests.swift` compiles the real editor store against the C++
  backend. It checks committed headings/drafts, one-command rename undo/redo,
  selection changes, color actions with stale table snapshots, unbound field
  creation, arrow/field ownership, deletion, uniqueness, duplication after typing,
  invalid names, and detachment before handle release.
- Native refinement checks in both Mac frontends confirm Return commits names,
  headings update immediately, color actions preserve drafts, Add field offers
  Index/Connection, and new connections start unbound. SwiftUI checks also verify
  field renaming followed by Unique, then saving a focused name draft from a clean
  file; the saved SQLite metadata contains that name and the uniqueness setting.
  GPUI checks verify a connection dragged onto a table header and its read-only
  primary-key destination. Latest signed iPhone update was installed successfully
  with `--no-launch`, respecting the user's choice to open SubCard themselves.
- An injected metadata-write failure verifies the surrounding savepoint rolls
  back generated SQL DDL together with metadata and does not alter history.
- The ER suite also passes under AddressSanitizer and UndefinedBehaviorSanitizer.
- `./scripts/build.sh all`: both Mac app bundles build and ad-hoc sign; runtime
  dependency/signature checks pass. No additional package was installed: serde
  and serde_json were already in GPUI's locked dependency graph and are now also
  direct dependencies. Both offer Apache-2.0-compatible licensing.
- `./scripts/build-iphone.sh`: unsigned arm64 iPhone build succeeds; verification
  confirms packaged and Mach-O iOS 16.0 minimum and system runtime dependencies.
- SwiftUI visual checks: table creation/rename, indexed/secondary fields, separate
  initial placement, fit, wheel panning, port dragging to create a connection,
  connection selection/inspector, keyboard undo, save, and divider resizing.
- GPUI visual checks: table/field creation and naming, port dragging and arrow
  selection, cascade editing with keyboard undo, move undo, copy/paste, deletion,
  zoom to 144%, and overflow scrollbar rendering.
- `./scripts/run.sh iphone --device IPHONE_UDID`: the completed app was rebuilt,
  development-signed using the existing environment, installed, and launched on
  the connected iPhone 12 Pro Max. A subsequent device process query confirmed
  SubCard was running. No signing identifiers were added to published files.
- Cross-frontend test: a GPUI-created People/Notes model saved as a test document
  reopened in SwiftUI with its fields, relationship and 144% zoom restored.

Builds and test artifacts stay under `.build/` on the external drive. The SwiftUI
build retains the older `onChange` overload for iOS 16 compatibility; current
macOS SDKs emit deprecation warnings. GPUI's pre-existing dependency graph emits
future-compatibility notices for `block` and `proc-macro-error2`.

Physical iPhone canvas gestures, navigation and file-provider interactions are
ready for the user acceptance test; they have not yet been exercised for this
feature. Installation and launch are verified. Linux/Windows runtime checks remain outside
the project's current Mac test scope. The geometry and GPUI editor introduce no
Mac-only dependencies. Physical 1 cm calibration requires a ruler on the actual
display; font em size is not the same measurement as visible glyph ink.

### Earlier manual regression procedure (historical)

1. Create two tables, add a unique index and a connection field, and drag the right
   port onto the other table's primary/index port. Select the arrow and switch
   cardinality and delete policy. Confirm the highlight and inspector update.
2. Move, recolor, rename, duplicate, copy/paste and delete a table; undo and redo
   each action. Delete a referenced field/table and undo to restore its links.
3. On iPhone, confirm Table only adds/selects; check the bordered Zoom/Edit menus,
   Fit, percentage presets, clipboard actions and Undo/Redo. Pinch off-center in
   both directions, including near the origin, and verify the initial midpoint
   stays over the same model point without moving tables.
4. Pan by dragging/scrolling, zoom in/out, use Fit and 100%, and operate both
   overflow scrollbars. Confirm these do not consume model undo or clear redo.
5. Rename a table using Return, then by changing color without Return, then by
   returning from iPhone details to the canvas. Confirm the heading and canvas
   update and each rename can be undone. From a saved clean document, type a name
   and press Save directly; reopen to confirm the final draft was saved.
6. Add an unconnected Connection from the canvas and from Add field. Select it,
   drag to another table's header, then retarget to a unique index. Confirm details
   show the destination read-only. Select an Index and toggle Unique; confirm
   non-unique indexes cannot be connection targets and referenced unique indexes
   cannot have uniqueness removed. Undo/redo the field, link and option changes.
7. Resize the Mac inspector; on iPhone, select a table/arrow, edit on the details
   screen and return. Test the same gestures with schema locked and in use mode.
8. Save, reopen, and compare positions/colors/zoom/pan/calibration. Open the file
   in the other frontend. Confirm real data/locks survive layout-only edits.

Mac Model-menu shortcuts: Shift-Command-T adds a table, Shift-Command-C/V copies
and pastes tables, Command-D duplicates, and Command-Z/Shift-Command-Z undo/redo.
GPUI uses platform Copy/Paste and Undo/Redo shortcuts when the canvas is focused;
Delete/Backspace removes the selection. Text inputs keep their own shortcuts.

## Table relationship acceptance checks

- Backend regressions cover A → B generating its hidden reference in B, automatic
  nonunique/unique indexes, query-plan index use, foreign-key rejection, optional
  references, cardinality changes, undo/redo, deletion cleanup, cascade/block,
  parallel/self/cyclic arrows, save/reopen, transaction rollback, fake-data
  protections, real-data locks and version-1 real-data preservation.
- The real SwiftUI editor store checks creation without visible fields, source
  selection without a model mutation, arrow-only selection, cardinality undo/redo,
  deletion/restore, invalid destinations, duplicate isolation, name-draft commits,
  hidden legacy keys and conceptual legacy-arrow direction.
- GPUI tests cover conceptual/legacy direction, hidden-key table height, parallel
  routes and self-loop geometry, plus the existing viewport regression cases.

Manual desktop/iPhone procedure: create A and B; drag A's right circle onto B;
select the 1:N label; change it to 1:1 and back; verify undo/redo and deletion.
Repeat using Relationship followed by a destination tap, and with a self arrow.
Save and reopen across frontends. Old documents must show table arrows without
keys/index controls and preserve existing rows. iPhone touch interactions require
a physical-device acceptance check; compilation alone does not verify gestures.

Verified on macOS on 2026-10-18 for the table-relationship update:

- `./scripts/test.sh` passes all backend, document, Swift viewport and real editor
  store suites. It also verifies bundle signatures and system runtime dependencies.
- GPUI `cargo test --locked --manifest-path apps/gpui/Cargo.toml` passes all three
  viewport/relationship tests after sourcing `scripts/environment.sh` in Bash.
- `./scripts/build.sh all` builds and signs both Mac apps.
- `./scripts/build-iphone.sh` builds the unsigned arm64 app and verifies the
  packaged and Mach-O iOS 16.0 minimum and system-only runtime dependencies.
- Native SwiftUI checks verify table naming, direct A → B dragging, table-only
  presentation, arrow-label selection, 1:N/1:1 changes and keyboard undo.
- Native GPUI checks verify table-only presentation, toolbar relationship
  creation, arrow/label selection, cardinality changes and keyboard undo.
  A SwiftUI-created document reopens in GPUI, and GPUI's changed cardinality
  persists across reopening. The low-zoom label remains readable above its arrow.

Build/cache/test output stays inside `.build/` on the external drive. Existing
SDK deprecation and Rust dependency future-compatibility warnings remain.
This update was not installed or touch-tested on the physical iPhone. Linux and
Windows remain outside the current runtime test scope.


## Table-only destinations and animated reveal (2026-10-18)

Relationship details explicitly show **From: table name** and **To: table name**
in SwiftUI and GPUI. Destination keys, primary-key descriptions and physical SQL
column names are never part of those labels, including for older documents.

When **+ Table** changes the camera position, both frontends ease the pan over
0.5 seconds. The existing table and background move across the canvas so a new
table appearing in the same screen position is visibly a different canvas location.
Zoom and calibration stay fixed. Adding a table that already fits does not pan.
Repeated additions start from the currently displayed camera position. Pointer,
touch and wheel navigation can interrupt the reveal and continue from that position.

The final viewport is committed once through the shared command boundary before
the display animation starts. Animation frames are transient frontend state:
SwiftUI updates a presentation camera on the main actor; GPUI requests display
frames and samples a monotonic clock. Drawing, handles, scrollbars and hit testing
use that presentation camera. No animation frame writes to SQLite or consumes
undo history. Saving during the move persists the final camera, and animation
frames cannot make the saved document dirty. Replacing a document cancels the old
animation. Undo still removes a newly created table in one step.

Verification: backend/Swift editor/viewport suites and four GPUI tests pass;
both Mac builds and the unsigned iOS 16 build pass. The real SwiftUI store test
checks intermediate motion, repeated-add continuity, completion, gesture
interruption, save-during-animation and one-step undo. Native checks in both Mac frontends
confirm table-only From/To labels and Add Table behavior, including the GPUI
third-table reveal. GPUI schedules subsequent frames from rendering. The paired
physical iPhone was disconnected, so its installed app was not refreshed.

After the iPhone was reconnected on 2026-10-18, a live device-details check
confirmed the paired wired connection and developer services. The latest app was
rebuilt, development-signed, verified for iOS 16.0 and installed successfully on
the iPhone 12 Pro Max using `run-iphone.sh --no-launch`. The user will open it
manually to test the table-only connection details and animated table reveal.

## Typed fields in the inspector (2026-10-18)

Ordinary fields are edited exclusively in the details pane. The canvas remains a
table/relationship diagram with fixed-height table headers. See
[Typed fields](typed-fields.md) for the version-3 commands, datatypes, constraints,
optional indexing, blob purposes and verification. Version-1/2 legacy keys remain
hidden; relationships still generate their references and indexes automatically.

## Simplified table nodes (2026-10-18)

Both frontends draw tables as a single solid-color rounded rectangle with a
selection outline. The old header/body treatment and white bottom strip have
been removed. Table geometry, text, ports, drag targets and relationships retain
their existing behavior. Fields remain exclusively in the inspector.

Relationship creation is available through the canvas toolbar or by dragging
between table ports. The redundant Create relationship button and its helper
text have been removed from the inspector; relationship property editing remains
in the inspector when an arrow is selected.

Verification: native SwiftUI and GPUI checks confirm the solid rounded shape,
selection outline and canvas relationship control, with no duplicate inspector
button. Both Mac builds and the existing regression suites pass. The update was
development-signed, verified for iOS 16 and installed on the paired iPhone with
`--no-launch` for manual testing.

## iPhone table selection and activation (2026-10-18)

A single tap selects a table on iPhone and leaves the canvas visible. A double
tap opens the selected table's details screen. Desktop single-click selection
continues to update the side-by-side inspector. The same iPhone policy applies
in editing and use modes. Separate single taps on an already-selected table do
not open details.

The UIKit canvas forwards the native touch tap count to the existing end-of-drag
handler. There is no delayed single-tap recognizer; selection remains immediate.
Movement, pinch cancellation and pending relationship gestures keep their
existing handling. The frontend store owns selection/navigation, and taps do not
change the document or consume undo history. The Swift editor suite exercises
compact single/double taps, desktop selection, use-mode selection and draft
commit ownership. Physical touch acceptance remains for the iPhone test.

Verification: the full backend/Swift editor suite and Mac SwiftUI build pass. A
native Mac check confirms a single click updates the adjacent inspector. The
updated signed iOS 16 app was installed on the paired iPhone with `--no-launch`
for physical single/double-tap acceptance testing. The desktop test instance was
quit after verification.
