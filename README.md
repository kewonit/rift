# Rift

Rift is an open-source, native macOS content-filter firewall for Apple silicon
Macs. It uses SwiftUI, AppKit, NetworkExtension, SystemExtensions, and Swift 6
strict concurrency. Core 1.0 targets macOS 15 and later and builds only
`arm64` binaries.

> **Pre-release status:** The non-filtering source lane builds, and its automated
> tests pass. Signed live-filtering, clean-install, fault, and soak testing are
> not complete, and no signed build has been published. Do not treat this
> repository as a released or independently verified firewall.

## Apple membership requirements

You can clone, inspect, change, test, and compile the source at no cost. The
unsigned local lane does not require an Apple account. A free Personal Team can
sign ordinary personal apps, but it does not make Rift's full content-filter
lane generally runnable or distributable.

To run Rift as a system-wide firewall, provision the host app and system
extension with Apple-authorized App Group, System Extension, and Network
Extension capabilities. To distribute a download from GitHub, you also need
Developer ID signing and notarization. An Apple Developer Program team provides
these assets. Signed live-filtering evidence and Mac App Store validation are
still pending.

Apple references:

- [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Network Extensions entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension)
- [Supported macOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)

In short:

| Use | Free local lane | Paid Apple program/team |
|---|---:|---:|
| Read, modify, and run package tests | Yes | No |
| Compile the unsigned app, extension, and CLI | Yes | No |
| Test the Live Map, cable map, and UI fixtures | Yes | No |
| Exercise pure rule/history/archive/IPC logic | Yes | No |
| Activate the system-wide content filter | No | Yes, with matching capabilities and profiles |
| Publish a notarized GitHub download | No | Yes, with Developer ID and notarization |

For contributors, a GitHub source archive or clone provides a free build, test,
and UI lane. It does not turn the unsigned app into a functioning system-wide
firewall. A contributor with an authorized Developer Program team can supply
their own identifiers and profiles for signed integration testing.

For end users, the intended distribution is a paid Mac App Store download.
End users will not need an Apple account beyond the normal App Store account or
their own developer membership. They will need to approve the Network Extension
and system extension in macOS. Store receipt, clean-install, and entitlement
validation are still pending.

## Build the unsigned local lane

Requirements:

- Apple silicon Mac
- macOS 15 or later
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

Before any source publication or release candidate, run the stricter gate:

```sh
./Scripts/release-local-audit.sh
```

The gate includes the unsigned workflow. It also verifies release metadata and
the tracked publication inventory. It does not stage, delete, rewrite, or
publish anything.

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

## Map

The Live Map draws the world's undersea internet cables on Apple Maps and shows
which cables your connections most likely use, with traffic flowing along them.
You place this Mac on the map yourself; Rift never looks up your location. For
each public destination, Rift finds the country in a bundled IP-to-country table
on the Mac, then estimates the path from your location across the cable map.
Destination addresses never leave the Mac.

Paths are estimates. Solid lines are cables mapped in OpenStreetMap; dashed
lines are main sea routes drawn from where cables come ashore, because
OpenStreetMap doesn't map every cable. Country data can be wrong for VPNs,
relays, and content delivery networks. The bundled data and how to rebuild it
are described in the [third-party notices](THIRD_PARTY_NOTICES.md).

MapKit requests imagery and labels from Apple as you pan and zoom; Rift doesn't
give Apple destination IP addresses, hostnames, app identities, or firewall
decisions.

## Signed integration and distribution

The repository contains no Team ID, certificate, provisioning profile, notary
credential, or signing secret. When an authorized Apple Developer Program team
is available, follow the [build and signing guide](docs/release/build-signing.md).
The paid Mac App Store lane still requires capability approval, App Store
Connect/TestFlight validation, and clean-machine filtering, recovery, and
performance tests. Direct distribution has a separate notarization gate.

## Design and safety boundaries

- Rift fails open when no compatible, validated policy is available.
- Rift does not collect packet payloads or complete URLs. It does not use
  analytics or upload diagnostics automatically.
- Privacy-hidden flows do not enter monitor history or user-visible aggregates.
- New installations keep connection history in memory only: up to 10 recent
  connections for five minutes in visible activity views, or five in the menu
  panel alone. Hidden activity views stop collection and release those buffers.
  Persistent history is opt-in; saved rules remain enforced either way.
- The app owns editable user configuration. The extension owns the validated,
  durable enforcement cache.
- Rift does not enable a remote blocklist URL or an automatic updater. Country
  lookups for the map use a bundled table on the Mac. Apple MapKit requests the
  visible basemap region.

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
