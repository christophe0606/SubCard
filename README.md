# SubCard

A modern, multiplatform project inspired by HyperCard and science-fiction
subspace.

The bootstrap provides two desktop applications, one using **SwiftUI** and one
using **GPUI**. Each opens a resizable **SubCard** window displaying **Hello World**,
returned by the same C++ function. SQLite document stacks and card editing are
planned; they are not implemented yet.

## Architecture overview

```text
backend/                   Shared C++17 core with a C-compatible public API
apps/swiftui/              SwiftUI frontend, built with SwiftPM
apps/gpui/                 Rust + GPUI frontend, built with Cargo
scripts/                   Build and launch helpers
documentation/            Architecture, features, and development details
```

Both frontends compile the same C++ backend. Swift imports its public header
through a Clang module; Rust calls it through C FFI. Shared application logic and
future document storage belong in C++; windowing and presentation belong in the
frontends. GPUI is intended for macOS/Linux and later Windows; SwiftUI is intended
for macOS/iOS. Both desktop versions are currently verified on macOS only.

## Quick start on macOS

Requires Xcode, its Metal compiler component for GPUI, and an existing current
stable Rust toolchain. Keep this checkout on the external drive, then run:

```sh
./scripts/run.sh swiftui
./scripts/run.sh gpui
```

Build both without launching them with `./scripts/build.sh all`. The scripts keep
package caches and build artifacts in `.build/` on the checkout's volume and
produce `.build/apps/swiftui/SubCard.app` and `.build/apps/gpui/SubCard.app`.

## Documentation

- [Architecture and principles](documentation/architecture.md)
- [Development, prerequisites, build storage, and platform scope](documentation/development.md)
- [Hello World feature and verification](documentation/features/hello-world.md)

Document new features and architecture decisions in `documentation/` and link
them here so the project retains its implementation history and principles.

## License

SubCard is licensed under [Apache-2.0](LICENSE). See
[third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses and preserved
upstream attribution. Cargo dependencies are locked for repeatable builds.
