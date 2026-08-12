# Privacy

Abyss is designed to make firewall decisions on the Mac. It has no analytics,
advertising SDK, telemetry service, remote IP lookup, automatic diagnostics
upload, or packet-payload capture. Core 1.0 does not enable a remote blocklist,
automatic geolocation updater, or software-update service.

## Data kept on the Mac

- Editable configuration contains rules, profiles, groups, blocklist metadata,
  app/process identity conditions, notes, and local settings in the signed app's
  container.
- The system extension keeps only the validated compiled current/previous policy,
  ownership state, bounded expiry metadata, and recovery indexes in its separate
  root-owned container. It does not keep connection history.
- Connection history is enabled by default with a 30-day and 50,000-flow cap.
  It contains bounded decision metadata and close-reported byte totals when
  macOS supplies them. Users can lower retention, turn persistence off, or clear
  history. Privacy-hidden decisions do not enter visible history or aggregates.
- Rule-use counters are separate from connection history and can be cleared
  separately.
- Notifications are private by default. Abyss never includes complete URLs or
  packet contents in prompts, history, logs, or diagnostics.
- Application names and icons are read only from currently installed local apps.
  A candidate must exactly match the recorded code-signing identity before its
  artwork is shown. Artwork is cached in memory, is not added to history or
  exports, and is never uploaded; unavailable or ambiguous matches use a generic
  icon.
- If the user manually imports DB-IP City Lite, Abyss stores the validated IP
  ranges, approximate locations, source version/date, and import date in an
  owner-only local SQLite index. Lookups occur only on the Mac. Rejected imports
  do not replace the last valid index.

## Destination map network behavior

The destination map is hidden by default. When a user shows it, Apple's MapKit
requests map tiles for the coordinate regions currently in view. Abyss supplies
approximate coordinates to MapKit; it does not send destination IP addresses,
hostnames, application identities, rules, or connection history to DB-IP or a
remote lookup service. Apple Maps' own handling of map requests is governed by
Apple's services and privacy terms.

Local, private, loopback, multicast, broadcast, Bonjour, missing, and database-
unmatched endpoints are not plotted. Approximate IP geolocation can be stale or
incorrect and must not be treated as a person's identity or precise address.

## Exports and sharing

Configuration archives exclude history, counters, machine identifiers, policy
lineage/generation, and signing material. Diagnostics are created only after a
user action, preview their contents, default to aggregate/redacted state, and
are never uploaded automatically. Optional recent activity and rule summaries
use fresh pseudonyms that are linkable only within that one bundle.

Exported files leave Abyss's control. Review them before sharing and use a secure
channel. Do not include private traffic data or Apple signing credentials in a
public issue.

## Removal and recovery

In-app extension removal retains editable configuration and history unless the
user clears them separately. Abruptly deleting the app may leave the approved
system extension and its last durable policy active; follow the recovery steps
in [runtime limitations](docs/release/runtime-limitations.md). This document
describes the pre-release source behavior and should be reviewed again before a
public binary release.
