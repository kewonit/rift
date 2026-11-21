# Runtime limitations and recovery

Rift is early software. The unsigned source build exercises the
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
this release scope. Mac App Store validation is still pending.

## Filtering behavior

Rift filters new TCP and UDP flows through the macOS Network Extension
content-filter surface. Other IP traffic, such as ICMP (ping), isn't filtered in
any mode, including Block Unless Allowed. It does not inspect packet payloads or
complete URLs. A blocklist name, or a host in a rule you make in Rift, matches
that exact host, not its subdomains. Only a domain rule (shown as `*.name`),
which can arrive in an imported configuration, also covers subdomains. An existing connection can remain established until the application
or operating system opens another flow. A policy change does not promise to
terminate every already-open connection immediately.

When the extension has no compatible, validated policy, Rift fails open instead
of silently disconnecting the Mac. This also applies to unavailable or degraded
policy persistence. Before the status surface describes a saved policy as
enforced, it must confirm the active provider tuple.

Rules apply to your account and to processes running as root. Blocklists apply
to every account on the Mac. When you aren't at the console, before login or
while another account is in front, nobody can answer an alert, so connections
that would ask are allowed. Rift still identifies the app behind connections from
your account and from root, so app rules apply, and Block Unless Allowed still
blocks connections with no rule. Connections from other accounts, and ones whose
owner Rift can't determine, are allowed unless a blocklist covers them.

An incoming rule's destination is the service on this Mac: its address and
port. Two conditions describe the remote peer instead: a blocklist's addresses,
and "Local network", which matches an incoming connection only when the peer is
on a network this Mac is directly connected to. Because a rule can't name the
peer, Rift won't make an Allow rule that overrides a blocklist for an incoming
connection: it would let every listed address reach that service. Turn off the
blocklist entry instead.

`riftctl profiles activate` won't make a switch that weakens protection or that
Rift would ask you to confirm: a weaker mode, Pause Rules or Block Unless
Allowed, or a profile change that turns off rules that block or turns on rules
that allow. Make those switches in Rift.

Alert decisions have deadlines. If the app cannot answer safely before a
deadline, the runtime uses the configured bounded fallback. It resumes the flow
exactly once. Identity resolution failures suppress potentially private monitor
metadata when Rift cannot establish privacy eligibility.

## Activity and byte totals

New installations use temporary observed activity: up to 10 connections for five
minutes while the Map page is visible, or five for the menu panel alone.
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
archive or remove it through the verified uninstall path. If no known-good
archive exists, Settings › Advanced offers Reset Configuration… while the
database is damaged. It keeps the filter installed, saves a private copy of the
damaged configuration, deletes your rules, profiles, groups, and blocklists, and
starts fresh in Allow and Watch. All traffic is allowed until the reset
finishes.

For an unrecoverable local problem, preserve the affected files. Do not publish
connection metadata or policy contents. Follow the private reporting process in
the [security policy](../../SECURITY.md).
