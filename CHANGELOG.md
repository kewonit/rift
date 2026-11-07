# Changelog

The changelog records notable user-visible changes. Rift has no signed public
release.

## Unreleased

- The Map page now fills the window. Connections, the timeline and the
  inspector float over the map, and the connection list expands into a table
  with columns (⌘T). The Activity page is part of the Map page; the views are
  now Map, Rules and Status.
- The map draws the cable network faintly and the routes your connections
  likely use in bold, with new markers and a smaller legend.
- One timeline shows traffic or decisions for the chosen time range.
- The menu-bar panel was rebuilt with a mode menu, recent apps with their
  decisions, and standard menu rows.
- Rift has an app icon.
- Lists show verified app names instead of signing identifiers where Rift can
  match the installed app.
- Rift uses much less energy while the map is open: route animation, map
  updates and app-icon lookups do far less work, and launch no longer waits
  for the databases to open.
- Rift releases the map 30 seconds after its window is hidden, roughly halving
  its memory while it runs in the background.
- Fixed app names in connection alerts showing replacement characters.
- Status, the menu-bar panel and the Map now give the same plain description
  of what Rift is doing. Rift no longer says the Mac is protected when
  connections are simply being allowed, and it says when all connections are
  allowed or your rules can't be confirmed.
- Problems shown in the menu-bar panel and on the Map now give the reason and a
  direct way to fix them.
- Fixed the menu-bar icon disappearing in Alert mode.

## 0.3.0 (pre-release)

- Redesigned the app to follow macOS conventions: a labeled view switcher
  (Map, Activity, Rules, Status), native inspectors, clean lists with row
  actions on hover, and a calmer color palette.
- Settings now open in their own window (⌘,) with standard tabs.
- The Status page uses a grouped layout like System Settings.

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
