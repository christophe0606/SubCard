# SubCard

A modern, multiplatform project inspired by HyperCard and science-fiction
subspace.

Two desktop applications, using **SwiftUI** and **GPUI**, share a C++ document
backend. Both create, open, edit, and save `.subcard` documents: single SQLite
databases containing the document's data. SQLite is statically linked into both
applications. Native macOS File menus provide New, Open, Save, and Save As;
both save commands are dimmed while unchanged. Unsaved-change prompts protect
edits on New/Open/Close/Quit. Keyboard shortcuts follow the target platform.

A native **iPhone app for iOS 16 and later** uses the same backend and document
format, with a mobile editor and Files-based Open/Save controls. Its build,
development signature, USB installation, and launch on an iPhone 12 Pro Max are
verified. On-device editor and file-provider interactions still need testing.

The current editor is a small document-text field initialized with **Hello World**
from C++. Full card editing and scripting are future work.

Each document separates application-owned system tables from its user-defined
entity/relationship schema. User data has one global state across **all user
tables**: none, fake, or real. Empty/fake documents open in editing mode; documents
with real data open in use mode and can return to editing. The first real data
permanently locks the user schema: version 1 has no schema migration. Fake data
can be discarded to change its schema. The shared core enforces these rules;
the current interfaces provide basic mode controls while detailed mode-specific
workflows remain future work.

## Architecture overview

```text
backend/                   Shared C++17 core with a C-compatible public API
vendor/sqlite/             Verified SQLite source, statically compiled
apps/swiftui/              SwiftUI frontend, built with SwiftPM
apps/iphone/               iPhone Xcode application target and shared scheme
apps/gpui/                 Rust + GPUI frontend, built with Cargo
scripts/                   Build and launch helpers
documentation/            Architecture, features, and development details
```

Both frontends compile the same C++ backend and SQLite source. Swift imports the
core's public header through a Clang module; Rust calls it through C FFI. Shared
application logic and document storage live in C++; windowing and presentation belong in the
frontends. GPUI is intended for macOS/Linux and later Windows. SwiftUI builds for
macOS and iPhone. Desktop runtime tests cover macOS; iPhone verification covers
compilation, signing, installation, and launch on a physical phone.

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

Build the unsigned physical-iPhone app, using the installed iOS SDK and no
simulator, with `./scripts/build-iphone.sh`. The result is
`.build/apps/iphone/SubCard.app`; it requires signing before installation.

After signing into an Apple Account in Xcode and exporting `SUBCARD_TEAM_ID`,
`SUBCARD_BUNDLE_ID`, and `SUBCARD_SIGNING_IDENTITY`, build and development-sign with
`./scripts/sign-iphone.sh --device IPHONE_UDID`. The signed app is written to
`.build/apps/iphone-signed/SubCard.app`. See the [iPhone guide](documentation/features/iphone.md#command-line-development-signing)
for device selection, team settings, and prerequisites.

Rebuild, sign, install, and launch on a connected iPhone without opening Xcode:

```sh
./scripts/run.sh iphone --device IPHONE_UDID
```

The same signing environment is required. Enable Developer Mode and trust this
Mac on the iPhone; keep it unlocked for launch. Use `--no-launch` to install only.
You can export `SUBCARD_IPHONE_UDID` instead of passing `--device` each time.

## Documentation

- [Architecture and principles](documentation/architecture.md)
- [Document lifecycle, global data states, modes, and schema locking](documentation/features/document-lifecycle.md)
- [Development, prerequisites, build storage, and platform scope](documentation/development.md)
- [Hello World feature and verification](documentation/features/hello-world.md)
- [SQLite documents, menus, shortcuts, format, and verification](documentation/features/documents.md)
- [iPhone app, unsigned device build, file handling, and verification](documentation/features/iphone.md)
- [Application icons, artwork sources, and packaging](documentation/features/icons.md)

Document new features and architecture decisions in `documentation/` and link
them here so the project retains its implementation history and principles.

## License

SubCard is licensed under [Apache-2.0](LICENSE). See
[third-party notices](THIRD_PARTY_NOTICES.md) for dependency licenses and preserved
upstream attribution. Cargo dependencies are locked for repeatable builds.
