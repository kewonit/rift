# Privacy

Rift makes firewall decisions on the Mac. It does not use analytics, an
advertising SDK, a telemetry service, automatic diagnostics upload, or
packet-payload capture. It doesn't geolocate connections, and it doesn't send
destination IP addresses to any service. Core 1.0 does not enable a remote
blocklist or software updates.

## Data kept on the Mac

- The signed app's local container stores editable configuration: rules,
  profiles, groups, blocklist metadata, app and process identity conditions,
  notes, and local settings.
- The system extension's separate, root-owned container stores only the
  validated compiled current and previous policies, ownership state, bounded
  expiry metadata, and recovery indexes. It does not store connection history.
- New installations do not save connection history. Optional activity keeps at
  most 10 recent connections in memory for five minutes while Activity or Live
  Map is visible, or five when only the menu panel is open. Collection stops and
  these buffers are released when all activity views are hidden, minimized,
  fully obscured, or closed. Rules and prompt handling remain active.
- Persistent history is opt-in, with default limits of 30 days and 50,000 flows.
  It contains bounded decision metadata and close-reported byte totals when
  macOS supplies them. Existing history preferences are preserved. Turning
  recording off keeps old logs; deleting them requires Clear History.
  Privacy-hidden decisions do not enter visible history or aggregates.
- Rule-use counters are separate from connection history. Users can clear them
  separately. New usage is recorded only while persistent history is enabled.
- Rift keeps notifications private by default. It never includes complete URLs
  or packet contents in prompts, history, logs, or diagnostics.
- Rift reads application names and icons only from installed local apps. It
  shows artwork only when a candidate exactly matches the recorded code-signing
  identity. It caches artwork in memory, does not add it to history or exports,
  and never uploads it. Unavailable or ambiguous matches use a generic icon.
- If you place this Mac on the map, Rift saves that location in the app's local
  preferences, rounded to `0.25°`. Rift never looks up your location: it makes
  no IP-address request and doesn't use Location Services. Choose **Clear My
  Location** in the map's **My Location** menu to remove it.

## Map network behavior

The Live Map uses Apple MapKit for map imagery, labels, and geographic context.
MapKit communicates with Apple while the map is visible and when you pan or
zoom. Rift doesn't give Apple destination IP addresses, hostnames, application
identities, rules, firewall decisions, or connection history.

The map shows only the location you place for this Mac. Rift doesn't look up
where connections go and doesn't plot destinations.

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
