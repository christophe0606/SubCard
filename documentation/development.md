# Development

## Prerequisites

Use an existing Xcode installation with its command-line tools selected via
`xcode-select`, a C++17 compiler, and a current stable Rust toolchain for GPUI.
The bootstrap was built using Swift 6.4 and Rust 1.98.1 on Apple silicon.
The project scripts do not install toolchains or system packages.

For GPUI's standard macOS build, install Apple's Metal compiler component through
Xcode > Settings > Components > Metal Toolchain, or:

```sh
xcodebuild -downloadComponent MetalToolchain
xcrun --sdk macosx metal --version
```

Xcode manages that component's installation location. `-exportPath` can save an
exported download to an external drive; it is not an installation-directory
setting. SubCard's build scripts never download or install that component.

GPUI also supports `runtime_shaders` on macOS if a machine does not have the
standalone compiler. That option embeds source and compiles shaders through the
system Metal API at launch, instead of embedding a precompiled Metal library.

For Linux native development dependencies, consult the
[GPUI prerequisites](https://github.com/zed-industries/zed/tree/main/crates/gpui).
Linux builds are not validated by this bootstrap.

## Build and launch

From the checkout root:

```sh
./scripts/build.sh all
./scripts/build.sh swiftui
./scripts/build.sh gpui
./scripts/run.sh swiftui
./scripts/run.sh gpui
./scripts/test.sh
./scripts/build-iphone.sh
./scripts/run.sh iphone --device IPHONE_UDID
```

`run.sh` builds the requested variant before launching it. On macOS, bundles are
written to `.build/apps/swiftui/SubCard.app` and
`.build/apps/gpui/SubCard.app`. Both are named SubCard, with separate bundle
identifiers so they can run together. They are locally signed with ad-hoc
signatures and are not notarized distribution packages. On Linux, the GPUI helper
builds and launches `.build/gpui/debug/subcard-gpui` directly.

## External-drive build storage

Keep the checkout on the external drive and use the scripts to retain cache
routing. `scripts/environment.sh` directs these files to ignored `.build/` paths:

| Files | Directory |
| --- | --- |
| Cargo registry and dependency source | `.build/cargo-home/` |
| Rust artifacts | `.build/gpui/` |
| Swift artifacts | `.build/swiftui/` |
| SwiftPM configuration/security state | `.build/swiftpm/` |
| SwiftPM, compiler module, and XDG caches | `.build/cache/` |
| Temporary build files | `.build/tmp/` |
| Development app bundles | `.build/apps/` |

The first GPUI build downloads and compiles a large dependency graph. Later builds
reuse it. Removing `.build/` reclaims these files but requires a fresh dependency
download and build. Bare `cargo`/`swift` commands do not necessarily inherit these
locations. Existing tools and operating-system-managed runtime files are separate
from this project storage.

Cargo builds use the checked-in lockfile with `--locked`. Review dependency license
changes when updating it; see [third-party notices](../THIRD_PARTY_NOTICES.md).
Rust 1.98.1 currently reports future-compatibility warnings in upstream `block`
0.1.6 and `proc-macro-error2` 2.0.1; the current build succeeds.

SQLite is vendored in `vendor/sqlite` and built statically by SwiftPM/Cargo;
no system SQLite development package is required. Its archive checksum and source
provenance are recorded beside the source. SwiftPM's SDK warning settings may
report narrowing conversions in the unmodified upstream amalgamation.

`test.sh` builds a standalone C++ persistence test against the same SQLite source
and runs it under `.build/tests/`. When app bundles exist on macOS, it also checks
their runtime library paths against the OS directories. Manual menu/panel and
cross-frontend checks are recorded in [SQLite documents](features/documents.md).

The [iPhone target](features/iphone.md) builds with `./scripts/build-iphone.sh`
(or `./scripts/build.sh iphone`). Its minimum deployment target is iOS 16.0.
It uses the installed device SDK and produces
an unsigned `.build/apps/iphone/SubCard.app` without a simulator download or
connected phone. The build verifies arm64/iPhoneOS metadata and system-only
runtime dependencies. `scripts/test.sh` also verifies that bundle when present.
For development signing, export `SUBCARD_TEAM_ID`, `SUBCARD_BUNDLE_ID`, and
`SUBCARD_SIGNING_IDENTITY`, then run `./scripts/sign-iphone.sh` (optionally with
`--device IPHONE_UDID`). To rebuild, sign, install, and launch on that phone, run
`./scripts/run.sh iphone --device IPHONE_UDID`. This uses Apple's command-line
tools without opening Xcode, with the same external build/cache paths. See the
iPhone guide for device prerequisites and verification status.

The Mac bundles and iPhone target use the checked-in [application icons](features/icons.md).
After changing a PNG master, regenerate the native delivery formats with
`./scripts/prepare-icons.sh`; intermediate icon sets stay in `.build/icons/`.
