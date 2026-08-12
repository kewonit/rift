# Dependency and data inventory

| Component | Exact version/revision | License | Shipping scope | Removal seam |
|---|---|---|---|---|
| GRDB.swift | 7.10.0 / `36e30a6f1ef10e4194f6af0cff90888526f0c115` | MIT | App-only configuration/history repositories | Replace `RiftControl` repository implementation |
| Swift Argument Parser | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Apache-2.0 with Runtime Library Exception | Embedded `riftctl` argument parsing only | Replace the CLI command front end; IPC/file-safety code is separate |

The Rift maintainers own dependency review. Before each release candidate—and
at least monthly while development is active—they review upstream release and
security notices, the GitHub Security Advisory database, and the Swift Package
Index package record. Last local review: 2026-08-12. A version or revision
change requires a new license, transitive-dependency, product-linkage, and
signed-runtime review before these exact pins are updated.

There are no shipping UI, chart, map, update, or geolocation dependencies. Swift Charts, AppKit/SwiftUI, NetworkExtension, Security, CryptoKit, ServiceManagement, UserNotifications, and SystemConfiguration are system frameworks. No third-party blocklist or geolocation data ships. GRDB's optional SQLCipher/plugin dependencies are not enabled. The workspace lock pins both remote packages, and the standalone `RiftControl` package lock independently pins GRDB; neither dependency floats on a branch.

The machine-readable inventory is [sbom.spdx.json](sbom.spdx.json), and license
attributions intended to accompany source and binary distributions are in
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md). The local release audit
parses all three checked-in lockfiles and requires the exact reviewed identity,
URL, version, and revision sets; it also requires the revisions to match the
SBOM and notices.

GitHub Actions uses the official `actions/checkout` v6.0.2 action pinned to
revision `de0fac2e4500dabe0009e67214ff5f5447ce83dd`. It is build tooling only and
is not shipped in Rift. The workflow runs on the standard Apple-silicon
`macos-26` image with Xcode 26.6 selected explicitly.
