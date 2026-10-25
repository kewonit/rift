# Runtime limitations and recovery

Rift is a pre-release project. The unsigned source build exercises the
interface, rule engine, persistence, and IPC models. It cannot activate the
macOS content filter. Do not rely on an unsigned build as a
system-wide firewall.

## Supported environment

- Apple silicon Macs only
- macOS 15 or later
- One interactive console user controls the installed filter
- A signed host app and system extension with matching Apple-authorized
  capabilities for live filtering

Intel Macs, remote administration, and automatic remote list updates are outside
this release scope. Mac App Store validation remains a signed release gate.

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

New installations use temporary observed activity: up to 10 connections for five
minutes while Activity or Live Map is visible, or five for the menu panel alone.
Hidden, minimized, fully obscured, and closed activity views stop optional
collection and release its buffers. Opening a view starts a new observation
period. Charts cover these limited observations; historical navigation requires
opting into persistent history. Existing history preferences and old logs are
preserved, and saved rules remain enforced in either mode.

Rift bounds monitor history. History can be partial after provider restarts,
storage failures, dropped runtime events, or periods when the app cannot persist
activity. Rift displays partial byte totals as lower bounds. It uses an
unavailable value when no trustworthy measurement exists. It never converts a
missing measurement to zero.

History stays on the Mac. Rift excludes privacy-hidden flows from persisted
history and user-visible aggregates. Exported diagnostics are redacted and are
never uploaded automatically.

## Map

The Live Map shows undersea internet cables and the location you place for this
Mac, rounded to `0.25°` and saved on this Mac. For each public destination,
Rift looks up the country in a bundled table on the Mac and estimates the cables
the connection most likely uses. It never sends destination addresses to a
lookup service.

These are estimates. Country data describes where an address is routed and can
be wrong for VPNs, relays, and content delivery networks. Solid cable lines come
from OpenStreetMap, which doesn't map every cable; dashed lines are main sea
routes drawn from where cables come ashore. Rift can't observe the physical path
a connection takes. Local, private, and unknown destinations aren't plotted, and
blocked connections show a marker without a path because they never left the
Mac.

Apple MapKit supplies the basemap and communicates with Apple for the visible
map region; Rift doesn't give Apple destination IPs, hostnames, app identities,
or firewall decisions.

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
