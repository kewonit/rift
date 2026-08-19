# Rift

Rift is an open-source, native macOS content-filter firewall for Apple silicon
Macs. It uses SwiftUI, AppKit, NetworkExtension, SystemExtensions, and Swift 6
strict concurrency. Core 1.0 targets macOS 14 and later and builds only
`arm64` binaries.

<img width="1392" height="791" alt="Rift Monitor with application activity on a destination map" src="https://github.com/user-attachments/assets/312cf59c-a527-4a59-ac07-12f4c8db7ba6" />

> **Pre-release status:** The non-filtering source lane builds, and its automated
> tests pass. The signed Network Extension, clean-install, fault, soak, and
> notarization release gates are not complete. Do not treat this repository as a
> released or independently verified firewall.

## Apple membership requirements

You can clone, inspect, change, test, and compile the source at no cost. The
unsigned local lane does not require an Apple account. A free Personal Team can
sign ordinary personal apps, but it does not make Rift's full content-filter
lane generally runnable or distributable.

To run Rift as a system-wide firewall, provision the host app and system
extension with Apple-authorized App Group, System Extension, and Network
Extension capabilities. To distribute a download from GitHub, you also need
Developer ID signing and notarization. An Apple Developer Program team provides
these assets. The Mac App Store is not required.

Apple references:

- [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Network Extensions entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
- [Supported macOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)

In short:

| Use | Free local lane | Paid Apple program/team |
|---|---:|---:|
| Read, modify, and run package tests | Yes | No |
| Compile the unsigned app, extension, and CLI | Yes | No |
| Test the offline location index and synthetic MapKit fixture | Yes | No |
| Exercise pure rule/history/archive/IPC logic | Yes | No |
| Activate the system-wide content filter | No | Yes, with matching capabilities and profiles |
| Publish a notarized GitHub download | No | Yes, with Developer ID and notarization |

For contributors, a GitHub source archive or clone provides a free build, test,
and UI lane. It does not turn the unsigned app into a functioning system-wide
firewall. A contributor with an authorized Developer Program team can supply
their own identifiers and profiles for signed integration testing.

For end users, the intended future distribution is a Developer ID-signed and
notarized GitHub release. End users will not need an Apple account or paid
membership. They will need to approve the Network Extension and system
extension in macOS. No App Store submission is planned.

## Build the unsigned local lane

Requirements:

- Apple silicon Mac
- macOS 14 or later
- Xcode 26.6 or newer with the command-line tools selected

Run the maintained unsigned build workflow:

```sh
./Scripts/test-nonfiltering.sh
```

The workflow runs all four Swift package suites. It creates an unsigned Release
build. It checks that the app, extension, and embedded CLI are arm64-only and
correctly contained. It does not install, launch, activate, or modify a system
extension. The same script is the only job in the GitHub Actions workflow. That
job is named **Unsigned arm64 audit (no filtering)** and publishes no app
artifact.

Before any source publication or release, run the stricter gate:

```sh
./Scripts/release-local-audit.sh
```

The gate includes the unsigned workflow. It also verifies release metadata and
the tracked, source-only publication inventory. It does not stage, delete,
rewrite, or publish anything.

For the lighter pure-package lane:

```sh
swift test --package-path Packages/RiftCore
swift test --package-path Packages/RiftIPC
swift test --package-path Packages/RiftControl
swift test --package-path Packages/RiftFilterRuntime
```

Package tests cover the deterministic matcher, policy and state machines, and
bounded IPC and file transfer. They cover root policy-store recovery,
configuration and history repositories, backups, and archives. They also cover
diagnostics redaction, monitor logic, and rule logic. They do not claim that
live macOS filtering works.

## Check the offline destination map

The bounded DB-IP CSV importer, local SQLite index, lookup logic, and native
MapKit presentation work in tests without a paid Apple membership. Package
tests cover importer and index behavior. The isolated Debug UI fixture uses
synthetic locations to exercise the map without opening the live App Group,
history databases, XPC, or extension APIs.

The live Debug and Release apps do not expose **Map Data**, CSV import, or
**Show Map**. The live map remains disabled until signed MapKit self-traffic and
interactive attribution and accessibility evidence pass. The fixture cannot
import a real database, and the live Debug surface does not bypass those
requirements.

Rift does not bundle an IP-location database or send destination IP addresses to
a remote geolocation API. For the optional connection-link origin, an admitted
map requests the public egress IP from ipify once per map session. It then
resolves that address locally and retains only a coarse session coordinate. The
reviewed database candidate is [DB-IP City Lite](https://db-ip.com/db/lite.php),
supplied by the user only if the feature is later admitted.

The August 2026 download is about 87.5 MB compressed. DB-IP reports 673.7 MB
for the extracted CSV. Sizes change monthly. Keep about 2 GB free while the CSV
and generated local index coexist. The importer streams data on a utility task
and accepts a maximum of 1 GiB and 10 million records.

The August 2026 production-size import gate passed locally with the official
706,430,977-byte CSV and all 7,926,653 records. It produced a 679,448,576-byte
SQLite index in 116.3 seconds with about 101 MB peak resident memory.
Representative IPv4 and IPv6 lookups succeeded. These figures describe that
source file and host. They are not a universal performance guarantee.

Locations are approximate. Local, private, multicast, broadcast, Bonjour,
missing, and unmatched destinations remain explicit list groups and are not
plotted. Any admitted surface must show source metadata and the required
**IP Geolocation by DB-IP** attribution. Database updates require manual import.
Rift uses no API key or automatic updater.

## Signed integration and GitHub releases

The repository contains no Team ID, certificate, provisioning profile, notary
credential, or signing secret. When an authorized Apple Developer Program team
is available, follow the [build and signing guide](docs/release/build-signing.md).
The release remains blocked until the clean-machine filtering, recovery,
performance, and notarization requirements pass.

## Design and safety boundaries

- Rift fails open when no compatible, validated policy is available.
- Rift does not collect packet payloads or complete URLs. It does not use
  analytics or upload diagnostics automatically.
- Privacy-hidden flows do not enter monitor history or user-visible aggregates.
- The app owns editable user configuration. The extension owns the validated,
  durable enforcement cache.
- Rift does not enable a remote blocklist URL or an automatic data updater. It
  imports the optional geolocation database manually and queries it only on the
  Mac. The optional map can request the Mac's public egress IP from ipify once
  per map session.

Read the [runtime limitations and recovery](docs/release/runtime-limitations.md),
[threat model](docs/security/threat-model.md), [privacy notice](PRIVACY.md),
and [third-party notices](THIRD_PARTY_NOTICES.md). The [software bill of
materials (SBOM)](docs/release/sbom.spdx.json) and [reproducibility and symbol
notes](docs/release/reproducibility.md) describe the current source candidate.

## Contribute or report a security issue

Read [the contribution guide](CONTRIBUTING.md) before changing code. Report
security issues as described in [the security policy](SECURITY.md). Do not
attach private network data or signing material.

Licensed under the [Apache License 2.0](LICENSE).
