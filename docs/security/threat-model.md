# Abyss Core 1.0 threat model

## Assets and boundaries

Untrusted inputs include network metadata, audit-token-derived code identity, blocklist/archive files, XPC messages, SQLite files, and another local user's requests. Trusted boundaries are the exact signed app peer, the system extension, its fixed root-owned store, the authorized owner UID/current console session, and canonical policy validation.

The App Group authorizes sandboxed Mach lookup but does not create a shared policy-file bridge: the app and root extension resolve different containers. The app alone owns `config.sqlite`, `history.sqlite`, and configuration backups. The extension alone owns fixed-name A/B compiled slots, ownership/high-water state, slot index, expiry tombstones, and bounded in-memory rings.

## Controls

- XPC uses exact app and CLI signing identifiers plus Team ID, privileged lookup, audit-token EUID/session authorization, one controller lease, role-specific capabilities, bounded secure DTOs, protocol/schema negotiation, and no PID-only authentication. Native connection requirement enforcement precedes role classification.
- Snapshot mutation binds owner UID, lineage, monotonic generation, hash, exact offsets, deadline, and one staging transfer. Hashes detect corruption; they do not resist root modification.
- Root files use fixed paths, no-follow opens, `0700` directory/`0600` files, atomic same-directory replacement, reopen/validation, A/B recovery, and mutation lock on ambiguous ownership.
- Callback work excludes disk, database, DNS/network, UI, icons, and synchronous signature inspection. Missing state follows documented allow/degraded behavior.
- Privacy-hide suppresses the event before the extension runtime ring, history, diagnostics, aggregates, and usage counters. An independently matched notification may cross only the separate bounded, expiring, app-controller-only ephemeral queue; default notifications exclude endpoint/path details and retain no reconstructable row.
- Archives, lists, IPC, queues, history, and display strings are size/count bounded. CLI archives cross the extension broker only as ordered 256 KiB-or-smaller chunks with total/deadline/concurrency limits; the extension does not stage the complete archive. No analytics, telemetry, payload capture, remote geolocation, or default network subscription exists.
- Corrupt configuration is never silently replaced or reconstructed from compiled root bytes. Corrupt history is moved intact into an owner-only quarantine before a clean history store is created; filtering configuration remains separate.
- In-app uninstall is an authenticated retryable two-phase operation: enter durable resetting/fail-open state, erase only fixed policy/index/expiry artifacts, verify absence, transition ownership to `unclaimed`, then request OS deactivation. It never deactivates first and claims cleanup afterward.

## Compromise boundaries

Arbitrary root authority can alter the extension cache and is outside the protection claim. Arbitrary same-user code that escapes normal sandbox/DAC restrictions may alter the user's source database; reconciliation still requires the exact signed app/controller path. Persistent self-protection and enterprise administration are deferred.
