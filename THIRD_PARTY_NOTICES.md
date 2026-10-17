# Third-party notices

SubCard's own source is licensed under Apache-2.0; see `LICENSE`.

## Direct dependencies

| Component | Version | License | Source |
| --- | --- | --- | --- |
| GPUI | 0.2.2 | Apache-2.0 | https://github.com/zed-industries/zed/tree/main/crates/gpui |
| cc (build-time only) | Locked in `apps/gpui/Cargo.lock` | MIT OR Apache-2.0 | https://github.com/rust-lang/cc-rs |
| SQLite | 3.54.1 | Public domain | https://www.sqlite.org/copyright.html |
| unicode-segmentation | Locked in `apps/gpui/Cargo.lock` | MIT OR Apache-2.0 | https://github.com/unicode-rs/unicode-segmentation |

GPUI is Copyright 2022 - 2025 Zed Industries, Inc. Its unmodified upstream license
and copyright notice are included in `licenses/GPUI-LICENSE-APACHE`. That license
applies to the GPUI crate; SubCard does not depend on the Zed editor application.
SwiftUI and the Apple SDKs are provided by the installed Apple developer tools.

## Bootstrap dependency review (2026-10-17)

The license declarations of all 708 registry packages in the locked Cargo graph
were inspected, including dependencies for other platforms. Every declaration
offers a non-GPL license. Select Apache-2.0 for `self_cell` 1.3.0 and `r-efi` 5.3.0
and 6.0.0, which also offer GPL-family alternatives. The graph includes the
separately licensed MPL-2.0 crates `cbindgen` 0.28.0 (build-time), `dwrote` 0.11.5
(Windows), and `option-ext` 0.2.0. Preserve those crates' own licenses and source
obligations when distributing them. This review covers declared package licenses;
it is not a generated set of distribution notices.

`apps/gpui/src/text_input.rs` is adapted from GPUI 0.2.2's `examples/input.rs`;
the source attribution and original Apache license are retained. The unmodified
SQLite amalgamation/header are vendored under `vendor/sqlite`, retaining their
original public-domain notices. Their archive checksum and provenance are
recorded in `vendor/sqlite/README.md`. SQLite is statically linked into both apps.

Cargo preserves upstream source archives, copyright notices, and license files
under `.build/cargo-home/registry/`. The lockfile records exact dependency versions
and source checksums. For packages offering alternative licenses, use the
Apache-2.0-compatible permissive option rather than a GPL-family alternative.

Binary redistribution must include the applicable notices for the dependencies
used on the target platform; the development bundle helper is not a release
packaging or license-notice generator.
