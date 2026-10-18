# Application icons (2026-10-18)

SubCard has three related book-and-spreadsheet app icons. The Mac SwiftUI
variant shows a book with a grid on its right page; the GPUI variant extends the
grid to both pages. The iPhone variant uses the same symbol on a full square
background. Pale pages, a blue/teal cover and a single orange cell tie the family
together without text or frontend labels.

The original PNG masters, exported macOS `.icns` files, generation prompts and
preparation instructions live in [assets/icons](../../assets/icons/README.md).
The artwork was generated for SubCard using the built-in imagegen tool. No icon
package, new runtime dependency, or external code was introduced.

## Integration

`scripts/build.sh` selects the Mac icon from the frontend variant, copies it into
the application bundle, and writes `CFBundleIconFile = SubCard.icns` into its
generated Info.plist before code signing. This keeps both Mac frontends separate
without changing the shared C++ backend or the GPUI Linux build path.

The Mac bundles also contain their variant's native `Assets.car` and declare
`CFBundleIconName = SubCard`. The original `.icns`-only presentation was observed
in Tahoe Finder as a small blue icon inside a large gray system tile. Native
Icon Composer packaging supplies the system enclosure directly. The shared
`assets/icons/macos-composition.json` scales the existing artwork by 1.25 over
a blue background; the PNG masters and iPhone icon stay unchanged. Xcode's
`actool` compiles both the native catalog and backward-compatible `.icns`.
See [Apple's Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

After signing, the Mac builder updates the enclosing `.app` modification date.
Replacing files inside `Contents` alone leaves that date unchanged, so macOS may
retain registration and icon data from an earlier development bundle. Before
opening a Mac app, `run.sh` force-refreshes only that bundle's Launch Services
registration with `lsregister -f`. No global Dock restart or icon-cache deletion
is required. If the app was already running before an icon change, quit it
normally and run the helper again: `open` activates an existing instance rather
than replacing its process, preserving any unsaved document.

The iPhone target includes `Assets.xcassets` in its resources phase and sets
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in both configurations. Its source
is an opaque 1024-pixel PNG; the installed asset compiler derives the required
device sizes. Both unsigned and signed builds use this catalog. The bundle
verifier checks the compiled catalog, home-screen PNGs and primary icon name.

Generated masters and exported delivery assets are checked in so ordinary builds
do not regenerate artwork or need an image service. Run
`./scripts/prepare-icons.sh` after changing the PNG masters or Mac composition. Temporary icon
packages and compiler outputs stay on the external checkout in `.build/icons/`.
Regeneration requires Xcode 26 or later; ordinary builds copy the checked-in
catalogs and `.icns` files. Account, device and
signing identifiers are not stored with the icons.

## Verification

Both Mac frontends rebuilt successfully with their matching `.icns` files and
`CFBundleIconFile` entries, and their signatures passed verification. The three
masters were checked as 1024-pixel PNGs, with RGB and no alpha for the iPhone
source. The selected Mac icon was also inspected at 128 pixels.

Unsigned and development-signed iPhone builds passed the updated bundle checks,
including the compiled icon catalog and iOS 16 minimum. The signed version was
successfully installed on the connected iPhone 12 Pro Max. Its subsequent launch
request was refused because the phone was locked; the updated app can be opened
after unlocking. The build and install confirm icon packaging, while the final
home-screen appearance still needs visual confirmation on the phone.

After the Mac registration refresh was added, both variants rebuilt and launched
through `run.sh`. The enclosing bundle dates changed, both running processes had
regular application activation policy and the expected separate bundle paths,
and the SwiftUI icon obtained through `NSRunningApplication.icon` contained the
book/grid artwork. The GPUI Dock icon was visually confirmed by the user. Both
bundle signatures remained valid; no global cache reset was used.

After native catalog packaging replaced the legacy-only icons, both Mac
frontends rebuilt and passed strict code-signature verification. Their bundled
catalogs and fallback icons matched the checked-in variant assets, and both
declared the native icon name. After refreshing each bundle's Launch Services
registration, both SwiftUI and GPUI icons were visually checked in Tahoe Finder:
the blue artwork fills the system enclosure with no large gray surround.
