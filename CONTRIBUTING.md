# Contributing

Read `README.md` for the free source lane and its signing boundary. Use Xcode 26.6 or newer with Swift 6 strict concurrency. Run `Scripts/release-local-audit.sh` for the Apple-silicon local lane; pull requests are expected to pass the identically named unsigned/non-filtering GitHub job. Keep production files below 500 lines, preserve existing formatting, add bounded tests for parsers/state machines, and never add payload capture, remote IP lookup, insecure blocklist URLs, broad signing requirements, or unbounded buffers.

Ordinary contributors cannot run the signed Network Extension lane without Apple's restricted entitlement, matching app/extension profiles, and macOS approval. Never commit teams, identities, profiles, certificates, notary credentials, or fixture secrets.
