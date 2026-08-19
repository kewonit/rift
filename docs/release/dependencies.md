# Dependency and data inventory

| Component | Exact version/revision | License | Shipping scope | Removal seam |
|---|---|---|---|---|
| GRDB.swift | 7.10.0 / `36e30a6f1ef10e4194f6af0cff90888526f0c115` | MIT | App-only configuration/history repositories | Replace `RiftControl` repository implementation |
| Swift Argument Parser | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Apache-2.0 with Runtime Library Exception | Embedded `riftctl` argument parsing only | Replace the CLI command front end. IPC/file-safety code is separate |

The Rift maintainers own dependency review. They review dependencies before each
release candidate and at least once a month while development is active. They
review upstream release and security notices, the GitHub Security Advisory
Database, and the Swift Package Index record. The last local review was
2026-08-12. Before they change a version or revision, they review the license,
transitive dependencies, product linkage, and signed runtime.

Rift has no shipping dependencies for UI, charts, maps, updates, or geolocation.
Swift Charts, AppKit and SwiftUI, NetworkExtension, Security, CryptoKit,
ServiceManagement, UserNotifications, and SystemConfiguration are system
frameworks. Rift does not ship third-party blocklist or geolocation data. GRDB's
optional SQLCipher and plugin dependencies are not enabled. The workspace lock
pins both remote packages, and the standalone `RiftControl` package lock also
pins GRDB. Neither dependency uses a floating branch.

The machine-readable inventory is the [software bill of materials
(SBOM)](sbom.spdx.json). License attributions for source and binary
distributions are in the [third-party notices](../../THIRD_PARTY_NOTICES.md).
The local release audit parses all three checked-in lockfiles. It requires the
exact reviewed identity, URL, version, and revision sets. It also requires the
revisions to match the SBOM and notices.

GitHub Actions uses the official `actions/checkout` v6.0.2 action at revision
`de0fac2e4500dabe0009e67214ff5f5447ce83dd`. This action is build tooling only.
Rift does not ship it. The workflow runs on the standard Apple silicon
`macos-26` image with Xcode 26.6 selected explicitly.
