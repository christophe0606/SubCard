# Entity relationship canvas

## Implementation plan and acceptance checks

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

Physical SQL names use stable IDs (`user_t<ID>`, `f<ID>`) independently of editable
labels. Every table has `id INTEGER PRIMARY KEY AUTOINCREMENT`. Indexed fields
are integer fields with a persisted `unique` option. New indexes default to unique,
preserving the original behavior; unchecking **Unique** generates a normal secondary
index that permits duplicate values. SQLite UNIQUE permits multiple NULL values.
Only unique indexes and the primary key may be foreign-key destinations. An index
with incoming connections must stay unique until those connections are disconnected.

The UI labels referencing fields **Connection (foreign key)**. These are nullable
integer fields with a right port; indexed fields have a left port and the primary
key port is in the header. Connections start unbound: adding a field does not add
an edge or an SQL REFERENCES constraint. The internal `secondary` field kind is
retained for document/command compatibility; it means a foreign-key field, not a
secondary index. Ordinary data fields are deferred.
A right-to-left arrow points from the referencing table to the referenced key.
`1:N` means one target can be referenced by many source rows; `1:1` adds UNIQUE
to the source key. Deletion blocks by default; cascade deletes referring rows
when the target row is deleted. Self references and cycles are allowed.

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
its details screen. Tap a table header, field, or arrow when you want to edit details.
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

## Field editor refinement plan and acceptance checks

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

## Command contract (version 1)

Commands have an `op` string and relevant properties. IDs are positive integers;
`targetField: 0` means the header primary key. Commands:
`add_table` (name,x,y), `update_table` (id,name,color), `move_table` (id,x,y),
`delete_table` (id), `paste_table` (table), `add_index` (table,name,kind,unique?),
`update_index` (table,id,name,unique?), `delete_index` (table,id),
`connect` (table,field,target,targetField), `update_connection` (id,many,cascade),
`delete_connection` (id), `undo`, `redo`, and `view` (zoom,panX,panY,calibration).
Kinds are `index` and `secondary` (Connection/foreign key in the UI). `unique` is
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

## Verification results

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

### Manual regression procedure

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
