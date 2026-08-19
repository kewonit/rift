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
notarization. It does require the authorized capabilities and profiles.

## Prepare a GitHub release

Publishing a working download on GitHub is direct distribution, not App Store
distribution. It requires Developer ID profiles and certificates and
notarization. Publishing source is free. Source users can run only the
non-filtering lane unless they provide their own authorized team and identifiers.

## Sign and verify a release

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
