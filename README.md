# Rift

Rift is an open-source, native macOS content-filter firewall for Apple-silicon
Macs. It is built with SwiftUI, AppKit, NetworkExtension, SystemExtensions, and
Swift 6 strict concurrency. Core 1.0 targets macOS 14 or later and produces
`arm64` binaries only.

<img width="1392" height="791" alt="Rift Monitor showing application activity on a destination map" src="https://github.com/user-attachments/assets/312cf59c-a527-4a59-ac07-12f4c8db7ba6" />

> **Pre-release status:** the non-filtering source lane builds and its automated
> tests pass. The signed Network Extension, clean-install, fault, soak, and
> notarization release gates have not run yet. Do not treat this repository as a
> released or independently verified firewall.

## What is free and what requires Apple membership?

Cloning, inspecting, changing, testing, and compiling the source is free. No
Apple account is needed for the unsigned local lane below. A free Personal Team
can sign ordinary personal apps, but it does not make Rift's full content-filter
lane generally runnable or distributable.

Running Rift as a real system-wide firewall requires both the host app and its
system extension to be provisioned with Apple-authorized App Group, System
Extension, and Network Extension capabilities. Shipping a downloadable build
from GitHub additionally requires Developer ID signing and notarization. Those
assets come from an Apple Developer Program team; the Mac App Store is not
required.

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

For contributors, a GitHub source archive or clone is a free build/test/UI lane;
it does not turn the unsigned app into a functioning system-wide firewall. A
contributor with their own authorized Developer Program team can supply their
own identifiers and profiles for signed integration testing.

For ordinary end users, the intended later distribution is a Developer ID-signed
and notarized GitHub Release. Those users will not need an Apple account or paid
membership; they will only need to approve the Network Extension and system
extension in macOS. No App Store submission is planned.

## Local non-filtering build

Requirements:

- Apple-silicon Mac
- macOS 14 or later
- Xcode 26.6 or newer with command-line tools selected

Run the maintained unsigned build workflow:

```sh
./Scripts/test-nonfiltering.sh
```

It runs all four Swift package suites, creates an unsigned Release build, and
checks that the app, extension, and embedded CLI are arm64-only and correctly
contained. It does not install, launch, activate, or modify a system extension.
The same script is the only job in the GitHub Actions workflow; that job is
explicitly named **Unsigned arm64 audit (no filtering)** and publishes no app
artifact.

Before any source publication or release, run the stricter gate:

```sh
./Scripts/release-local-audit.sh
```

It includes the unsigned workflow and also verifies release metadata and the
tracked, source-only publication inventory. It does not stage, delete, rewrite,
or publish anything.

For the lighter pure-package lane:

```sh
swift test --package-path Packages/RiftCore
swift test --package-path Packages/RiftIPC
swift test --package-path Packages/RiftControl
swift test --package-path Packages/RiftFilterRuntime
```

Package tests cover the deterministic matcher, policy/state machines, bounded
IPC and file transfer, root policy-store recovery, configuration/history
repositories, backups, archives, diagnostics redaction, and monitor/rule logic.
They intentionally do not claim that live macOS filtering works.

## Offline destination-map status

The bounded DB-IP CSV importer, local SQLite index, lookup logic, and native
MapKit presentation are implemented and testable without a paid Apple
membership. Package tests exercise importer/index behavior, while the isolated
Debug UI fixture uses synthetic locations to exercise the map without opening
the live App Group, history databases, XPC, or extension APIs.

No live Debug or Release app currently exposes **Map Data**, CSV import, or
**Show Map**. The live map remains disabled until signed MapKit self-traffic and
interactive attribution and accessibility evidence pass. The fixture cannot
import a real database, and the live Debug surface does not bypass those
requirements.

Rift does not bundle an IP-location database or call a remote geolocation API.
The reviewed candidate remains
[DB-IP City Lite](https://db-ip.com/db/lite.php), supplied by the user only if
the feature is later admitted.

The August 2026 download is about 87.5 MB compressed and DB-IP reports 673.7 MB
for the extracted CSV; sizes change monthly. Keep roughly 2 GB free while the
CSV and generated local index coexist. Import is streamed on a utility task and
is bounded to a 1 GiB CSV and 10 million records.

The August 2026 production-size import gate passed locally with the official
706,430,977-byte CSV and all 7,926,653 records. It produced a 679,448,576-byte
SQLite index in 116.3 seconds with approximately 101 MB peak resident memory;
representative IPv4 and IPv6 lookups succeeded. These figures are evidence for
that source file and host, not a universal performance guarantee.

Locations are approximate. Local, private, multicast, broadcast, Bonjour,
missing, and unmatched destinations remain explicit list groups and are not
plotted. Any admitted surface must show source metadata and the required
**IP Geolocation by DB-IP** attribution. Database updates are designed to be
manual; no API key or automatic updater is used.

## Signed integration and GitHub releases

The repository contains no Team ID, certificate, provisioning profile, notary
credential, or signing secret. Once an authorized Apple Developer Program team
is available, follow the [build/signing notes](docs/release/build-signing.md).
The release remains blocked until the clean-machine filtering, recovery,
performance, and notarization requirements pass.

## Design and safety boundaries

- Filtering fails open when no compatible validated policy is available.
- No packet payloads, complete URLs, analytics, or automatic diagnostics uploads
  are collected.
- Privacy-hidden flows do not enter monitor history or user-visible aggregates.
- The app owns editable user configuration; the extension owns the validated
  durable enforcement cache.
- No remote blocklist URL, remote IP lookup, or automatic data updater is
  enabled. The optional geolocation database is imported manually and queried
  only on the Mac.

See [runtime limitations and recovery](docs/release/runtime-limitations.md), the
[threat model](docs/security/threat-model.md), the [privacy notice](PRIVACY.md),
and [third-party notices](THIRD_PARTY_NOTICES.md).
The [SPDX SBOM](docs/release/sbom.spdx.json) and
[reproducibility/symbol notes](docs/release/reproducibility.md) describe the
current source candidate.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) before changing code. Report security
issues using [SECURITY.md](SECURITY.md), without attaching private network data
or signing material.

Licensed under the [Apache License 2.0](LICENSE).
