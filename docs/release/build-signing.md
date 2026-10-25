# Build and sign Rift

The local lane builds for Apple silicon (`arm64`) only. The
`Scripts/test-nonfiltering.sh` script runs package tests, creates a Release build
with signing disabled, and checks product architecture and embedding. It does
not need an Apple account or signing assets. It cannot activate the content
filter.

## Configure signed development

A free Personal Team can sign ordinary personal apps. It cannot support the
complete Rift firewall lane. Live content-filter testing requires an Apple
Developer Program team with matching capabilities and development profiles for
the app and extension:

- App Group
- System Extension
- Network Extension

This signed development lane does not require App Store submission or
notarization. Sign the app and extension with an Apple Development identity and
matching development profiles. Use the standard `content-filter-provider`
entitlement value for both products, and keep System Integrity Protection (SIP)
enabled. Register the shared App Group and assign it to both App IDs in the
developer portal. With automatic signing, set `REGISTER_APP_GROUPS = YES` so the
generated profiles explicitly authorize the shared App Group. Verify that each
embedded profile includes that authorization. If Xcode keeps selecting an older
profile, generate fresh macOS App Development profiles for both App IDs and
select them explicitly. Apple's
[Network Extension development guide](https://developer.apple.com/forums/thread/725805)
describes this workflow:

1. Copy the signed app to `/Applications` and launch that copy.
2. Activate the embedded system extension from the app.
3. Approve the extension and network filtering when macOS asks.

Neither disabling SIP nor enabling `systemextensionsctl` developer mode is a
prerequisite for this development workflow. Developer ID distribution uses the
separate signing and notarization procedure below.

The shared Mach service name must start with the exact App Group identifier:
`group.io.rift.firewall.control.<version>.<build>`. Do not prepend the Team ID to this service
name when the App Group itself uses the `group.` prefix. The app and extension
must use the same service name. Include the version and build to avoid the
[Network Extension upgrade registration issue](https://developer.apple.com/forums/thread/779395)
tracked by Apple as `FB17032197`.

## Choose the distribution lane

The intended paid lane is the Mac App Store. It requires an Apple Developer
Program organization or individual account, App Store Connect access, an app
record, agreements and banking/tax setup, and matching Mac App Store
distribution profiles for the app and extension. Confirm that Apple has enabled
the required Network Extension and System Extension capabilities for the exact
App ID before treating submission as available. Validate the archive with
App Store Connect and TestFlight before setting a publication date. App Store
builds do not use the Developer ID notarization procedure below.

A GitHub binary is a separate direct-distribution lane. It requires Developer
ID profiles and certificates plus notarization. Publishing source is free.
Source users can run only the non-filtering lane unless they provide their own
authorized team and identifiers.

## Sign and verify a direct-distribution release

Release signing requires a Team identifier supplied outside the source. Use
separate, matching Developer ID profiles for `io.rift.firewall` and
`io.rift.firewall.filter`. Configure the App Group, global Mach service,
restricted Network Extension entitlement, and hardened runtime.

The embedded `Contents/Helpers/riftctl` identifier is
`io.rift.firewall.cli`. It has no App Group, Network Extension, Keychain-group,
database, or network-client entitlement.

Follow these steps:

1. Sign `riftctl` and the system extension before the host app. Add timestamps.
2. Do not use `codesign --deep`.
3. Verify the designated requirements and entitlements for all three products.
4. Notarize and staple the release.
5. Install the app in `/Applications`.
6. Approve both macOS surfaces.
7. Run the serialized filter matrix.
8. Test uninstall and recovery.

Signed and notarized outputs are traceable, but they are not promised to be
byte-identical. Timestamps and notarization tickets vary.

## Use the embedded CLI

Invoke the app-bundled CLI at
`/Applications/Rift.app/Contents/Helpers/riftctl`. A user can create a symlink
in an existing personal `PATH`. Rift never writes `/usr/local/bin` or edits
shell startup files.
