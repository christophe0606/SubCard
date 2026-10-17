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

The greeting API returns a non-null, null-terminated UTF-8 string with static
lifetime. Neither caller modifies or frees it. Swift creates a `String`; Rust
validates UTF-8 and copies into a GPUI `SharedString`. Rust's unsafe block is
restricted to this documented FFI boundary. Both UIs display the returned value.

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
The SwiftUI source uses a `WindowGroup` and guards macOS-specific window sizing;
it can be reused with the core in an iOS app. An iOS Xcode application target,
signing, and simulator/device validation have not been added.

SQLite document stacks, cards, editing, and scripting remain future work. See the
[hello-world feature](features/hello-world.md) for the implemented scope.
