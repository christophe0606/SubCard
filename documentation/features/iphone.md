# iPhone application (2026-10-17)

## Scope

SubCard now has a native SwiftUI iPhone application target, in addition to the two
desktop versions. It targets iOS 16 and later on arm64 iPhones, including iPhone X.
The initial text
still comes from the shared C++ greeting function. The editor uses the same SQLite
document format and statically compiled SQLite source as the desktop apps.

The phone interface has a multiline text editor, document name/changed status,
keyboard Done button, a File menu with New/Open/Save/Save As, and a quick Save
button. Both save actions are disabled while unchanged. New and Open confirm
unsaved changes with Save / Don't Save / Cancel. Apple Files pickers select
documents and destinations; security-scoped URLs and file coordination handle
access through file providers. The app registers the `.subcard` type and supports
Open In. File-provider interaction has been compiled, not yet tested on a phone.

The text editor has a contrasting system background, a visible rounded border,
larger text, and a “Tap the text below to edit it” hint. An explicit **Edit text**
button focuses the editor and opens the keyboard; it becomes **Done** while
editing. The border uses the accent color while focused. These iPhone-only
affordances make the prototype text clearly editable in light and dark mode.

## Project and build

`apps/iphone/SubCard.xcodeproj` is a checked-in Xcode application project. Its
shared scheme is **SubCard-iPhone**. It compiles the existing `SubCardApp.swift`
entry point and `iOSDocument.swift`, and references the root's local Swift package
product `SubCardCore`. SwiftPM builds both the C++ core and vendored SQLite into
the executable. No separate backend copy, package generator, new third-party
dependency, or database service is required.

From the repository root:

```sh
./scripts/build-iphone.sh
# Equivalent: ./scripts/build.sh iphone
```

The command builds **generic/platform=iOS** using the installed **iphoneos** SDK.
The target currently supports physical iPhones only. It does not request a
simulator runtime, download one, launch a simulator, contact a phone, or request
provisioning. `all` in the desktop helper continues to mean both desktop apps.

All project-controlled build state goes under external-checkout `.build/`:

| Output | Location |
| --- | --- |
| Ready-to-sign app bundle | `.build/apps/iphone/SubCard.app` |
| Xcode products, intermediates, SDK/module caches | `.build/iphone/DerivedData/` |
| Local package build state | `.build/iphone/SourcePackages/` |
| Xcode package cache | `.build/cache/xcode-packages/` |
| Build temporary files | `.build/tmp/` |

The application is deliberately built with `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO`. This verifies device-target compilation and linking
without an Apple account or connected device. The resulting unsigned `.app` is
not installable as-is and is not an App Store/TestFlight archive or signed IPA.
When device testing is possible, open the project in Xcode, select the same
scheme and the connected iPhone, choose the appropriate signing team, then build
and run normally. Keep DerivedData on the external drive when using Xcode's UI.
Company device-management restrictions may prevent signing/developer deployment;
this build does not inspect or change those policies.

For command-line installation and launch without the Xcode editor, use the
[device deployment helper](#command-line-device-deployment) below.

## iOS 16 compatibility

The Swift package and both Xcode configurations declare iOS 16.0 as the minimum.
Building with a newer installed iOS SDK does not require that SDK's OS version on
the phone. The bundle verifier checks both `MinimumOSVersion` in Info.plist and
the executable's Mach-O minimum, so a newer accidental deployment target fails
verification.

The editor uses the iOS 16-compatible Files importer and the single-content-type
FileDocument exporter. Their iOS 17 cancellation-callback overloads are not used.
The importer resets its presentation binding when canceled. Export dismissal
defers snapshot cleanup until the next main-loop turn because SwiftUI sets the
binding to false before delivering a successful or failed export callback. A
completion consumes the snapshot first; cancellation releases the snapshot and
pending continuation without clearing document changes. The cleanup checks the
snapshot's identity so it cannot clear a newly started export.

NavigationStack and the remaining editor controls compile with the iOS 16
deployment target. Physical-device layout and Files interaction still require
testing on a working phone; no simulator runtime is installed for this work.

## Native file writer / C++ snapshot boundary

iOS file providers coordinate writes through Foundation and SwiftUI. The core's
opaque `SubCardSnapshot` owns an immutable serialization of the **entire** SQLite
database, including additional tables and binary resources. Swift copies the
bytes into a `FileDocument` value for the native exporter. An existing file is
replaced atomically inside `NSFileCoordinator`.

Taking a snapshot does not clear dirty state or change the document path. After
a successful platform write, `subcard_document_accept_snapshot` records that
snapshot's baseline and destination. Canceled or failed exports keep the
document changed. If edits occur after the snapshot, accepting it preserves those
later edits as unsaved. A snapshot from another document is rejected. Each
snapshot and document handle has a single owner and is released exactly once.

The UI disables editing while presenting file operations. Export data is immutable
and Sendable; background `FileDocument` serialization never accesses the UI-bound
C++ document handle. The working document remains in memory, with explicit saves;
unsaved changes are not recovered after process termination. Large documents and
background recovery remain future work.

## Verification boundary

The physical-iPhone target was compiled and linked for a minimum of iOS 16.0 with
Xcode 27.1 / iOS 27.1 SDK, in both unsigned and development-signed builds, without
a simulator installation. The signed bundle passed signature and signing-team
checks. Both bundles passed architecture, metadata, deployment-minimum, and runtime
dependency checks. The shared Mac SwiftUI target rebuilt successfully. Backend
tests passed and cover snapshot
round-trips, extra tables/blobs, canceled exports, late edits, ownership mismatch,
and failed path acceptance, along with existing desktop persistence tests.

The bundle's architecture, iOS platform/minimum version, metadata, and dynamic
dependencies are checked after building. Both desktop frontends are rebuilt
against the extended C++ API. On-device layout, Files provider behavior, and
corporate device policy remain unverified. A subsequent command-line development-signed build
succeeded; its code signature, signing team, embedded profile presence,
architecture, and runtime dependencies were verified.

## Command-line development signing

After signing into an Apple Account in Xcode Settings, use the signing helper
without opening the Xcode editor:

```sh
export SUBCARD_TEAM_ID='<your-team-id>'
export SUBCARD_BUNDLE_ID='com.example.SubCard'
export SUBCARD_SIGNING_IDENTITY='Apple Development'
xcrun xctrace list devices
./scripts/sign-iphone.sh --device YOUR_IPHONE_UDID
```

Use the physical iPhone's UDID from the device list. The helper rebuilds with
automatic development signing, allows Apple to register that destination device,
and requests the required signing assets. It does not install or launch the app.
Omit `--device` to build for a generic iOS destination using devices already
registered with the team; initial Personal Team provisioning may need a connected
phone and `--device`.

Replace the example team and bundle identifier with your own values. The three
signing settings are required environment variables, with no account-specific
fallbacks or command-line overrides. `SUBCARD_SIGNING_IDENTITY` selects a
certificate already available in Keychain; use its name or certificate hash to
select a specific identity. `Apple Development` lets Xcode select a matching
development identity for the team.

Enter these settings in your current shell or supply them through your execution
environment; the helper does not read or write `.env` files. It never exports
certificates or private keys and does not request or save passwords. Xcode uses
its existing account credentials and Keychain. Public certificates and provisioning
metadata are necessarily included in the generated signed app and may appear in
Xcode build output; generated `.build/` content is ignored by Git.

An expired paid membership does not establish eligibility to create
new profiles: the account must have an available development team, such as a
Personal Team for free device testing.

Signed build state is isolated under `.build/iphone-signed/`, with the verified
delivery bundle at `.build/apps/iphone-signed/SubCard.app`. The unsigned helper
keeps its existing output. Both use the checkout's external caches and temporary
directory. Xcode manages the small account/signing assets through its normal
system locations; the helper does not relocate those or install SDKs/runtimes.
The helpers explicitly redirect SwiftPM's manifest compiler module cache and
disable Xcode's shared manifest cache, which otherwise writes diagnostics to
the user's internal Library cache despite the package-cache path setting.

Before copying the generated delivery bundle, the helper verifies its iPhone
architecture and system dependencies, embedded provisioning-profile presence,
code signature, and matching signing Team ID. Build success still requires valid
signing credentials and Apple provisioning access. Signing does not override
company restrictions on development-app installation or Developer Mode.

## Command-line device deployment

With the signing environment above exported, keep the iPhone connected by USB
and run:

```sh
xcrun devicectl list devices
./scripts/run.sh iphone --device IPHONE_UDID
# Equivalent: ./scripts/run-iphone.sh --device IPHONE_UDID
```

Use the phone's hardware UDID, not a CoreDevice-specific UUID: the same identifier
is passed to both `xcodebuild` and `devicectl`. The helper requires an explicit
device, either through `--device` or the `SUBCARD_IPHONE_UDID` environment variable;
it never chooses another phone automatically. No account or device identifiers
are stored in project sources.

The helper checks device connectivity, calls `sign-iphone.sh` to rebuild and
verify a freshly signed app, installs `.build/apps/iphone-signed/SubCard.app`
using `xcrun devicectl device install app`, and launches the configured bundle
identifier using `xcrun devicectl device process launch`. A failure stops the
sequence: a failed build cannot install an older delivery bundle, and an install
failure cannot report a successful launch. Add `--no-launch` to install only.
The separate unsigned build and signing-only commands retain their behavior.

The Xcode application and iOS platform tools must already be installed, with an
account and development signing identity available. The editor need not be open
for routine rebuilds and deployments. On the iPhone, accept Trust This Computer,
enable Settings > Privacy & Security > Developer Mode, restart and confirm its
activation, and keep the phone unlocked for launch. Any required developer trust
confirmation must also be accepted on the phone. The script cannot bypass these
on-device confirmations or device-management restrictions. In an execution
sandbox, access to Apple's CoreDevice service may require running the deployment
outside that sandbox; a service timeout alone does not prove a USB failure.

Project-controlled products, caches, and temporary files remain on the external
checkout under `.build/`. Credentials and certificates continue to use the
existing environment, Xcode account configuration, and Keychain.

### Physical-device deployment verification (2026-10-18)

`./scripts/run.sh iphone --device IPHONE_UDID` completed successfully on a USB
connected iPhone 12 Pro Max with Developer Mode enabled. The command rebuilt the
app using the existing signing environment, passed arm64/iPhoneOS, iOS 16 minimum,
runtime dependency, and code-signature verification, installed the resulting app,
and received successful launch confirmation from `devicectl`. The Xcode editor
was not needed to run this command. Shell syntax and help routing were checked.
This verifies deployment and launch; manual editing and Files round-trips remain
to be tested on the phone.
