# Reproducibility and symbols

The maintained local lane builds an unsigned Apple silicon product. The
reference environment recorded on 2026-08-11 uses macOS 26.5.2 (`25F84`), Xcode
26.6 (`17F113`), and Apple Swift 6.3.3. The deployment target remains macOS 14.
All three shipped executables contain only `arm64`.

Run from a clean source checkout:

```sh
./Scripts/release-local-audit.sh
```

The script validates source and release metadata, runs all package suites, builds
with signing disabled, and inspects
`.build/DerivedData/Build/Products/Release`. The SHA-256 hash of the workspace
dependency lock is
`e9d43ad174ac4f16964859856294af1f0f45b44e7f8e5a5b794146b9ee2d7f81` for the
current source candidate. Dependency revisions also appear in the SPDX SBOM
and third-party notices.

## Keep symbol bundles

The Release build emits these symbol bundles:

- `Rift.app.dSYM`
- `RiftFilter.systemextension.dSYM`
- `riftctl.dSYM`

Product verification requires each `arm64` DWARF UUID to match its
corresponding binary. Retain the three symbol bundles privately with the exact
source revision and published artifact hashes. Symbols contain debugging
information and are not bundled with the user download.

## Understand reproducibility limits

Canonical policy artifacts and their cross-architecture golden fixtures are
deterministic. Whole Xcode products are not promised to be byte-for-byte
reproducible across different SDK and toolchain paths. Developer ID signatures,
secure timestamps, and notarization tickets are intentionally nondeterministic.
A binary release must instead be traceable to a source tag, dependency lock,
toolchain record, matching dSYMs, entitlements, designated requirements, and
published SHA-256 hashes.
