# Privacy

Rift makes firewall decisions on the Mac. It does not use analytics, an
advertising SDK, a telemetry service, automatic diagnostics upload, or
packet-payload capture. It does not send destination IP addresses to a remote
geolocation service. Core 1.0 does not enable a remote blocklist, automatic
geolocation updates, or software updates.

## Data kept on the Mac

- The signed app's local container stores editable configuration: rules,
  profiles, groups, blocklist metadata, app and process identity conditions,
  notes, and local settings.
- The system extension's separate, root-owned container stores only the
  validated compiled current and previous policies, ownership state, bounded
  expiry metadata, and recovery indexes. It does not store connection history.
- By default, Rift retains connection history for up to 30 days and 50,000 flows.
  History contains bounded decision metadata and close-reported byte totals when
  macOS supplies them. Users can lower retention, turn persistence off, or clear
  history. Privacy-hidden decisions do not enter visible history or aggregates.
- Rule-use counters are separate from connection history. Users can clear them
  separately.
- Rift keeps notifications private by default. It never includes complete URLs
  or packet contents in prompts, history, logs, or diagnostics.
- Rift reads application names and icons only from installed local apps. It
  shows artwork only when a candidate exactly matches the recorded code-signing
  identity. It caches artwork in memory, does not add it to history or exports,
  and never uploads it. Unavailable or ambiguous matches use a generic icon.
- When a user imports DB-IP City Lite, Rift stores validated IP ranges and
  approximate locations in an owner-only local SQLite index. It also stores the
  source version and date and the import date. Lookups occur only on the Mac. A
  rejected import does not replace the last valid index.

## Destination map network behavior

The destination map is hidden by default. The live map is not available in the
current Debug or Release app. When Rift admits the live map and a user shows it,
Apple MapKit requests map tiles for the coordinate regions in view. Rift
supplies approximate coordinates to MapKit. It does not send destination IP
addresses, hostnames, application identities, rules, or connection history to
DB-IP or a remote lookup service. Apple's services and privacy terms govern how
Apple handles map requests.

When Rift admits the live map, it makes one HTTPS request per map session to the
[ipify public IP API](https://www.ipify.org/). ipify returns the Mac's public
egress IP address. Rift resolves that address against the user-imported local
DB-IP database and immediately rounds the result to a `0.25°` coordinate. Rift
keeps only the rounded coordinate in memory. It does not add the public IP to
settings, history, diagnostics, or logs. ipify observes the request's source IP
and standard HTTPS metadata. A VPN, relay, carrier gateway, or corporate egress
can make this location differ substantially from the Mac's location.

Rift does not plot local, private, loopback, multicast, broadcast, Bonjour,
missing, or database-unmatched endpoints. Approximate IP geolocation can be
stale or wrong. Do not treat it as a person's identity or exact address.

## Exports and sharing

Configuration archives exclude history, counters, machine identifiers, policy
lineage and generation, and signing material. Diagnostics are created only after
a user action. They preview their contents, default to aggregate and redacted
state, and are never uploaded automatically. Optional recent activity and rule
summaries use fresh pseudonyms that are linkable only within that bundle.

Exported files are outside Rift's control. Review them before sharing. Use a
secure channel. Do not include private traffic data or Apple signing credentials
in a public issue.

## Removal and recovery

In-app extension removal keeps editable configuration and history unless the
user clears them separately. Deleting the app without completing removal can
leave the approved system extension and its last durable policy active. Follow
the recovery steps in [runtime limitations and recovery](docs/release/runtime-limitations.md).

This page describes pre-release source behavior. Review it before a public
binary release.
