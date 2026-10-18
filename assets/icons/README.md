# SubCard application icons

Original book-and-spreadsheet artwork generated with the built-in imagegen tool
on 2026-10-18 for this project. No external icon library or imported logo is used.
The prompt set is recorded in [generation-prompts.json](generation-prompts.json).

| App | PNG master | Delivery format |
| --- | --- | --- |
| Mac SwiftUI | `sources/mac-swiftui.png` | `mac-swiftui.icns` |
| Mac GPUI | `sources/mac-gpui.png` | `mac-gpui.icns` |
| iPhone | `sources/iphone.png` | `apps/iphone/Assets.xcassets/AppIcon.appiconset` |

All three masters are 1024 by 1024 pixels. The Mac variants have a transparent
surround around a rounded blue/teal tile. SwiftUI has a grid on the right book
page; GPUI has grids on both pages. The iPhone image is opaque RGB, full bleed,
with square corners so the OS can apply its own mask. Each icon has one orange
cell as a shared accent and no text or platform badge.

Run `./scripts/prepare-icons.sh` on macOS after changing a master. It uses the
installed `sips` and `iconutil` tools to produce 16, 32, 128, 256 and 512 point
Mac icon representations at 1x and 2x, and copies the iPhone master into the asset
catalog. Intermediate files stay under `.build/icons/`; an execution sandbox may
need to allow `iconutil` access to system image services. Normal builds consume
the checked-in delivery icons without running this preparation step.

The Mac bundle builder copies the variant-specific icon into
`Contents/Resources/SubCard.icns` and declares `CFBundleIconFile` before signing.
The iPhone project compiles its `AppIcon` catalog through the resources phase;
Xcode derives device resolutions from the 1024-pixel source. The iPhone verifier
requires the compiled catalog, home-screen icons, and primary icon metadata.
See [Apple's asset catalog guidance](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).
