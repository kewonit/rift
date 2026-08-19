# Runtime limitations and recovery

Rift is a pre-release project. The unsigned source build exercises the
interface, rule engine, persistence, IPC models, and offline map components. It
cannot activate the macOS content filter. Do not rely on an unsigned build as a
system-wide firewall.

## Supported environment

- Apple silicon Macs only
- macOS 14 or later
- One interactive console user controls the installed filter
- A signed host app and system extension with matching Apple-authorized
  capabilities for live filtering

Intel Macs, remote administration, automatic remote list updates, and App Store
distribution are outside this release scope.

## Filtering behavior

Rift filters new flows through the macOS Network Extension content-filter
surface. It does not inspect packet payloads or complete URLs. An existing
connection can remain established until the application or operating system
opens another flow. A policy change does not promise to terminate every
already-open connection immediately.

When the extension has no compatible, validated policy, Rift fails open instead
of silently disconnecting the Mac. This also applies to unavailable or degraded
policy persistence. Before the status surface describes a saved policy as
enforced, it must confirm the active provider tuple.

Alert decisions have deadlines. If the app cannot answer safely before a
deadline, the runtime uses the configured bounded fallback. It resumes the flow
exactly once. Identity resolution failures suppress potentially private monitor
metadata when Rift cannot establish privacy eligibility.

## Activity and byte totals

Rift bounds monitor history. History can be partial after provider restarts,
storage failures, dropped runtime events, or periods when the app cannot persist
activity. Rift displays partial byte totals as lower bounds. It uses an
unavailable value when no trustworthy measurement exists. It never converts a
missing measurement to zero.

History stays on the Mac. Rift excludes privacy-hidden flows from persisted
history and user-visible aggregates. Exported diagnostics are redacted and are
never uploaded automatically.

## Destination map

Destination locations are approximate database matches. They are not device
locations or observed packet routes. Rift does not plot private, loopback,
link-local, multicast, broadcast, missing, or failed lookups. CDNs, VPNs, and
relays can make a plotted endpoint differ from the service owner or user-facing
site.

Rift does not bundle a location database or send destination IP addresses to a
remote IP-geolocation API. If Rift admits the map lane, it will use a
user-supplied DB-IP City Lite CSV and resolve locations locally. To
estimate the connection-link origin, the map requests the public egress IP from
ipify once per map session. It stores no raw response and keeps only a `0.25°`
session coordinate. VPNs, relays, and shared gateways can make that origin
inaccurate. Apple MapKit requests map tiles for the viewed region. The live map
and database-import controls remain unavailable until their signed runtime,
production-size import, attribution, and accessibility gates pass.

## Recover from a filter problem

If filtering needs attention, open Rift. Use the filter-status control to retry
installation or approval. Use it to open the relevant macOS settings. Do not
delete Rift while its filter is active.

The uninstall action in Settings prepares a verified fail-open state before it
requests system-extension deactivation. If Rift cannot verify the preparation,
it leaves the extension installed and reports the failure. This avoids an
unknown enforcement state.

Configuration restore keeps a rollback anchor until it saves and reconciles the
replacement. You can recover a corrupt configuration database from a known-good
archive or remove it through the verified uninstall path. Rift does not provide
an in-place reset that preserves the installed extension when no known-good
archive exists.

For an unrecoverable local problem, preserve the affected files. Do not publish
connection metadata or policy contents. Follow the private reporting process in
the [security policy](../../SECURITY.md).
