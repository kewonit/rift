# Build and signing

The local lane is Apple-silicon (`arm64`) only. `Scripts/test-nonfiltering.sh` runs package tests, a Release build with signing disabled, and product architecture/embedding checks. It needs neither an Apple account nor signing assets, but it cannot activate the content filter.

A free Personal Team is suitable for ordinary personal apps, not for claiming the complete Rift firewall lane. Live content-filter testing requires an Apple Developer Program team whose app and extension identifiers have matching App Group, System Extension, and Network Extension capabilities and development profiles. This signed development lane does not require App Store submission or notarization, but it does require those authorized capabilities.

Publishing a working download on GitHub is direct distribution, not App Store distribution. It additionally requires Developer ID profiles/certificates and notarization. Publishing source alone is free, but ordinary source users can only run the non-filtering lane unless they provide their own authorized team and identifiers.

Release signing requires separate matching Developer ID profiles for `io.rift.firewall` and `io.rift.firewall.filter`, the App Group and global Mach service, the restricted Network Extension entitlement, hardened runtime, and a Team identifier supplied outside source. The embedded `Contents/Helpers/riftctl` identifier is `io.rift.firewall.cli`; it has no app-group, Network Extension, Keychain-group, database, or network-client entitlement. Sign the CLI and system extension before the host app, with timestamps; do not use `codesign --deep`. Then verify all three designated requirements and entitlements, notarize, staple, install in `/Applications`, approve both macOS surfaces, run the serialized filter matrix, and test uninstall/recovery. Signed/notarized outputs are traceable but not promised byte-identical because timestamps and tickets vary.

Invoke the app-bundled CLI directly as `/Applications/Rift.app/Contents/Helpers/riftctl`. A user may create a symlink in an existing personal `PATH`; Rift never writes `/usr/local/bin` or edits shell startup files.
