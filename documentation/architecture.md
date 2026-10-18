# Architecture

## Bootstrap: shared C++ core and two frontends (2026-10-17)

SubCard has one C++17 backend and two independent UI implementations:

```text
SwiftUI view -> SwiftPM Clang module -> C API -> C++ core
GPUI view   -> Rust C FFI            -> C API -> C++ core
```

The public boundary is `backend/include/SubCardCore.h`, a header usable by both
C and C++. `backend/src/SubCardCore.cpp` implements `subcard_greeting()` and is
compiled directly into each frontend's executable. SwiftPM handles the SwiftUI
build; Cargo's portable `cc` build dependency handles the GPUI build. There is no
copied backend implementation or manually maintained prebuilt library.

The greeting API supplies the initial document text. The document C API exposes
opaque owned handles, borrowed UTF-8 strings, and explicit operation results. The
C++ core catches errors before they cross the language boundary. Rust wraps each
handle in an owner with `Drop`; Swift keeps its owner within the main actor.

The iPhone target reuses the root Swift package's `SubCardCore` product. Immutable
full-database snapshots allow platform-managed Files writes without clearing the
shared dirty state until a write succeeds. The snapshot stores the source
document identity, saved text baseline, and schema/data revision; later edits
remain unsaved. See the [iPhone application](features/iphone.md) for the ownership
and save sequence.

## SQLite document layer (2026-10-17)

`backend/src/Document.cpp` owns system text mutations, format validation, session
mode, dirty tracking, and save semantics. `backend/src/UserData.cpp` owns user
schema/data transactions and the persistent lifecycle policy. An in-memory SQLite
working copy
separates editing from explicit saves. SQLite's backup API transfers the entire
database, including resources and additional tables. The UIs own panels, menus,
window titles, and confirmation flows, not persistence logic.

`vendor/sqlite` contains the verified upstream amalgamation, compiled as a static
library by both build systems. There is no external database service or SQLite
runtime installation. See [SQLite documents](features/documents.md) for format,
ownership rules, keyboard conventions, verification, and current limitations.

## Document lifecycle and application flow (2026-10-18)

A stack's database contains application-owned system tables and document-specific
user tables representing its entity/relationship schema. The global user-data
state is **None**, **Fake**, or **Real**, exclusively, for all user tables together.
System content, including the prototype text field, never counts as user data.

New documents start in editing mode. Opening a document with no user data or fake
data selects editing mode; real data selects use mode. Use mode can return to
editing mode. Mode is transient session state, while data provenance and the
schema lock persist with the document.

The first real data permanently locks the user schema because version 1 has no
user-schema migration. Returning to editing mode or deleting all real rows does
not lift that lock. Fake data can be discarded so its schema can be replaced.
All schema/data mutations pass through the shared backend's transactional policy
boundary rather than relying on UI controls for enforcement.

The [document lifecycle contract](features/document-lifecycle.md) specifies the
global states, mode transitions, storage primitives, compatibility defaults,
tests, and deferred design decisions. Detailed mode behavior and presentation,
ER editing, and record-entry workflows will be designed in later steps.

## Principles to preserve

- Put shared application logic and SQLite stack storage in C++, so the
  SwiftUI and GPUI frontends use the same behavior and document format.
- Keep platform UI concerns in the frontend; keep platform SDKs out of the core.
- Keep the C ABI explicit about ownership, encoding, lifetimes, and errors when
  adding operations. Do not pass C++ standard-library types across this boundary.
- Use portable build tools and platform-scoped dependencies in the GPUI frontend.
- Keep dependencies and build outputs on the external development volume.
- License SubCard under Apache-2.0, choose compatible third-party licenses, and
  retain upstream copyright and license notices. Do not select GPL alternatives.
- Document each new feature or architecture decision here in `documentation/`
  and link it from the root README. Record verification and platform limitations.

## Platform boundaries

The backend contains no platform-specific code. The GPUI crate retains its default
X11/Wayland support for Linux. Its Metal configuration is macOS-specific. The
frontend does not invoke a hardcoded compiler or linker. Windows will need native
build/packaging helpers rather than the current Bash scripts.

Both desktop frontends are verified on macOS. Linux and Windows are not tested.
The SwiftUI desktop scene uses a single `Window` and native AppKit document
panels. The iPhone scene uses navigation/toolbar controls and native Files pickers.
The iPhone application target has been built unsigned for arm64 iOS devices;
signing, installation, and device runtime checks remain separate steps. No iPhone
simulator runtime is needed for that build.

SQLite documents and text editing are implemented. Card layout and scripting
remain future work. The [hello-world feature](features/hello-world.md) records
the original bootstrap.

## Entity relationship editor

The [ER canvas architecture](features/entity-relationship-canvas.md) specifies the
versioned JSON command boundary shared by SwiftUI, GPUI and future scripting.
`ERModel.cpp` validates graph mutations, generates stable-ID SQLite table/index
and foreign-key definitions, stores layout/view metadata in system tables, and
owns model undo/redo. Frontends own rendering, hit testing, selection, clipboard
transport and inspectors. A completed move submits one command. Viewport writes
persist independently of history, so navigation cannot consume model undo.
