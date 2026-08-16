# Runtime limitations and recovery

Rift is currently a pre-release project. The unsigned source build exercises the
interface, rule engine, persistence, IPC models, and offline map components, but
it cannot activate the macOS content filter. Do not rely on an unsigned build as
a system-wide firewall.

## Supported environment

- Apple-silicon Macs only
- macOS 14 or later
- One interactive console user controls the installed filter
- A signed host app and system extension with matching Apple-authorized
  capabilities for live filtering

Intel Macs, remote administration, automatic remote list updates, and App Store
distribution are outside the current release scope.

## Filtering behavior

Rift filters new flows from the macOS Network Extension content-filter surface.
It does not inspect packet payloads or complete URLs. Existing connections may
remain established until the application or operating system opens another
flow, so a policy change is not a promise that every already-open connection is
terminated immediately.

When the extension has no compatible validated policy, Rift is designed to fail
open instead of silently disconnecting the Mac. This includes unavailable or
degraded policy persistence. The status surface must confirm the active provider
tuple before it describes a saved policy as enforced.

Alert decisions have deadlines. If the app cannot answer safely before the
deadline, the runtime uses the configured bounded fallback and resumes the flow
exactly once. Identity resolution failures suppress potentially private monitor
metadata when privacy eligibility cannot be established.

## Activity and byte totals

Monitor history is bounded and may be partial after provider restarts, storage
failures, dropped runtime events, or periods when the app could not persist
activity. Rift displays partial byte totals as lower bounds and uses an
unavailable value when no trustworthy measurement exists. Missing measurements
are never converted to zero.

History is local to the Mac. Privacy-hidden flows are excluded from persisted
history and user-visible aggregates. Exported diagnostics are redacted and are
never uploaded automatically.

## Destination map

Destination locations are approximate database matches, not device locations
and not observed packet routes. Private, loopback, link-local, multicast,
broadcast, missing, and failed lookups are not plotted. CDNs, VPNs, and relays
may make a plotted endpoint differ from the service owner or user-facing site.

Rift does not bundle a location database or use a remote IP-geolocation API. A
future admitted map lane uses a user-supplied DB-IP City Lite CSV and performs
lookups locally. Apple MapKit still requests map tiles for the viewed region.
The live map and database-import controls remain unavailable until their signed
runtime, production-size import, attribution, and accessibility gates pass.

## Recovery

If filtering needs attention, open Rift and use the filter-status control to
retry installation or approval and to open the relevant macOS settings. Do not
delete Rift while its filter is active.

The uninstall action in Settings prepares a verified fail-open state before it
requests system-extension deactivation. If preparation cannot be verified, Rift
leaves the extension installed and reports the failure instead of risking an
unknown enforcement state.

Configuration restore keeps a rollback anchor until the replacement is saved
and reconciled. A corrupt configuration database can be recovered from a known
good archive or removed through the verified uninstall path. An in-place reset
that preserves the installed extension when no known-good archive exists is not
currently provided.

For unrecoverable local problems, preserve the affected files, avoid publishing
connection metadata or policy contents, and follow the private reporting process
in [SECURITY.md](../../SECURITY.md).
