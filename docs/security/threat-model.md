# Rift Core 1.0 threat model

## Assets and boundaries

Untrusted inputs include:

- Network metadata
- Audit-token-derived code identity
- Blocklist and archive files
- XPC messages
- SQLite files
- Requests from another local user

Trusted boundaries include the exact signed app peer, the system extension, and
its fixed root-owned store. They also include the authorized owner UID, current
console session, and canonical policy validation.

The App Group authorizes sandboxed Mach lookup. It does not create a shared
policy-file bridge because the app and root extension resolve different
containers. The app alone owns `config.sqlite`, `history.sqlite`, and
configuration backups. The extension alone owns fixed-name A/B compiled slots,
ownership and high-water state, the slot index, expiry tombstones, and bounded
in-memory rings.

## Controls

- XPC uses the exact app and CLI signing identifiers, Team ID, privileged
  lookup, and audit-token EUID and session authorization. It also uses one
  controller lease, role-specific capabilities, bounded secure DTOs, and
  protocol and schema negotiation. XPC does not use PID-only authentication.
  Native connection-requirement enforcement runs before role classification.
- Snapshot mutation binds owner UID, lineage, monotonic generation, hash, exact
  offsets, deadline, and one staging transfer. Hashes detect corruption. They do
  not resist root modification.
- Root files use fixed paths and no-follow opens. Directories use `0700`. Files
  use `0600`. Same-directory replacement is atomic. Rift reopens and validates
  files, uses A/B recovery, and locks mutation when ownership is ambiguous.
- Callback work does not use disk, databases, DNS or network, UI, icons, or
  synchronous signature inspection. Missing state follows the documented
  allow/degraded behavior.
- Privacy-hide suppresses the event before it enters the extension runtime ring,
  history, diagnostics, aggregates, or usage counters. An independently matched
  notification can cross only the separate, bounded, expiring ephemeral queue
  available to the app controller. Default notifications exclude endpoint and
  path details. The queue retains no reconstructable row.
- Archives, lists, IPC, queues, history, and display strings have size or count
  bounds. The CLI sends archives through the extension broker as ordered chunks
  of 256 KiB or less, with total, deadline, and concurrency limits. The
  extension does not stage the complete archive. Rift has no analytics,
  telemetry, payload capture, remote geolocation, or default network
  subscription.
- Rift never silently replaces corrupt configuration or reconstructs it from
  compiled root bytes. It moves corrupt history intact into an owner-only
  quarantine before it creates a clean history store. Filtering configuration
  remains separate.
- In-app uninstall is an authenticated, retryable, two-phase operation. It
  enters a durable resetting and fail-open state. It erases only fixed
  policy/index/expiry artifacts. It verifies their absence. It changes ownership
  to `unclaimed`. It then requests OS deactivation. It never deactivates first
  and cleans up afterward.

## Compromise boundaries

Arbitrary root authority can alter the extension cache. The protection claim
does not cover it. Same-user code that escapes normal sandbox or DAC restrictions
may alter the user's source database. Reconciliation still requires the exact
signed app and controller path. Persistent self-protection and enterprise
administration are deferred.
