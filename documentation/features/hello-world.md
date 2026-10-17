# Hello World bootstrap

Implemented 2026-10-17.

## Behavior

Each frontend opens a resizable window titled **SubCard**, initially 640 by 400
points, and centers **Hello World** in it. Both call `subcard_greeting()` from the
same compiled C++ source; neither UI hardcodes the displayed greeting.

SwiftUI uses native window and menu behavior. GPUI provides an application menu
with Quit SubCard, Command-Q on macOS (Control-Q elsewhere), and quits when its
last window closes. Minimum desktop window size is 320 by 200 points.

## Verification

- Built the SwiftUI executable and GPUI executable on Apple-silicon macOS.
- Launched both app bundles and visually verified their window title and greeting.
- Checked GPUI's Command-Q behavior.
- Checked C++ compiler warnings, Rust formatting, shell syntax, app property
  lists, and local app signatures.
- Reviewed the declared licenses of the locked dependency graph; see
  [third-party notices](../../THIRD_PARTY_NOTICES.md).

The [architecture](../architecture.md) describes the C++ boundary.
[Development instructions](../development.md) cover building and external-drive
storage. This feature has no database or document editing yet. Linux, Windows,
and iOS runtime behavior has not been verified.
