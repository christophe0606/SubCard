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

## SQLite document layer (2026-10-17)

`backend/src/Document.cpp` owns the document schema, text mutations, format
validation, dirty tracking, and save semantics. An in-memory SQLite working copy
separates editing from explicit saves. SQLite's backup API transfers the entire
database, including resources and additional tables. The UIs own panels, menus,
window titles, and confirmation flows, not persistence logic.

`vendor/sqlite` contains the verified upstream amalgamation, compiled as a static
library by both build systems. There is no external database service or SQLite
runtime installation. See [SQLite documents](features/documents.md) for format,
ownership rules, keyboard conventions, verification, and current limitations.

## Principles to preserve

- Put shared application logic and future SQLite stack storage in C++, so the
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
panels; iOS retains the bootstrap greeting scene. The shared core is portable,
but an iOS document browser, signing, and simulator/device testing are not added.

SQLite documents and text editing are implemented. Card layout and scripting
remain future work. The [hello-world feature](features/hello-world.md) records
the original bootstrap.
