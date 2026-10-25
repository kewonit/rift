# Contributing

Read the [Rift overview](README.md) for the unsigned source lane and its
signing boundary.

## Prepare your environment

Use Xcode 26.6 or newer with Swift 6 strict concurrency. Run
`Scripts/release-local-audit.sh` for the Apple silicon local lane, and make sure
it passes before you open a pull request. The unsigned, non-filtering GitHub
Actions job runs on `main`.

## Keep changes safe

- Keep production files below 500 lines.
- Preserve existing formatting.
- Add bounded tests for parsers and state machines.
- Do not add payload capture, IP geolocation or remote lookups of destination
  addresses, insecure blocklist URLs, broad signing requirements, or unbounded
  buffers.

## Work with signed features

Ordinary contributors cannot run the signed Network Extension lane. It requires
Apple's restricted entitlement, matching app and extension profiles, and macOS
approval.

Never commit team identifiers, signing identities, profiles, certificates,
notary credentials, or fixture secrets.
