# Contributing

Read the [Rift overview](README.md) for the unsigned source lane and its
signing boundary.

## Prepare your environment

Use Xcode 26.6 or newer with Swift 6 strict concurrency. Run
`Scripts/release-local-audit.sh` for the Apple silicon local lane. Pull requests
must pass the matching unsigned, non-filtering GitHub Actions job.

## Keep changes safe

- Keep production files below 500 lines.
- Preserve existing formatting.
- Add bounded tests for parsers and state machines.
- Do not add payload capture, remote lookups of destination IP addresses,
  insecure blocklist URLs, broad signing requirements, or unbounded buffers.

## Work with signed features

Ordinary contributors cannot run the signed Network Extension lane. It requires
Apple's restricted entitlement, matching app and extension profiles, and macOS
approval.

Never commit team identifiers, signing identities, profiles, certificates,
notary credentials, or fixture secrets.
