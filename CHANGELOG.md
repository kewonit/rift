# Changelog

The changelog records notable user-visible changes. Rift has no signed public
release.

## 0.2.0 (pre-release)

- The Live Map now shows the world's undersea internet cables on Apple Maps,
  with a Map and Satellite style. Connections to other countries follow their
  most likely cables, with traffic flowing along the route.
- Added a bundled IP-to-country table and cable map, built from ip-location-db
  (public domain), OpenStreetMap (ODbL), and Natural Earth. Lookups stay on the
  Mac; `Scripts/build-network-data.sh` rebuilds the data from pinned sources.
- Rewrote the text throughout the app in plain language.

## Unreleased (0.1.0 source)

- Added the initial Apple silicon macOS firewall source tree, native app,
  content-filter system extension, and embedded `riftctl` command-line client.
- Added deterministic rule evaluation, durable policy reconciliation, bounded
  alert handling, rules, profiles, groups, blocklists, bounded connection
  history, configuration archives, backups, and redacted diagnostics.
- Added the free non-filtering source workflow and unsigned arm64 app, extension,
  and CLI product verification.
- Added explicit fail-open recovery behavior, preservation of corrupt
  configuration and history, bounded persistence, XPC authorization and
  timeouts, and release documentation.
- Removed the DB-IP database and importer, the vendored libmaxminddb reader,
  and the ipify public-IP request. You place this Mac on the map yourself.

The signed Network Extension, clean-machine, soak, fault-injection, and
notarization gates remain open. This section does not announce a release.
