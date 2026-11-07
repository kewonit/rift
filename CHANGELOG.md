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
- Every blocked connection now reads as Blocked, including ones blocked by your
  mode, and counts, filters and search all agree. Each connection shows its
  result and the reason in plain words.
- The menu-bar panel no longer says there were no connections when Rift simply
  wasn't keeping history.
- A copy of Rift that can't filter, such as a build from source, now says so as
  soon as it opens.
- Filter problems now offer the button that fixes them, such as Turn On Filter
  or Finish Setup, and trying again works after macOS declines the filter.
- Rift now explains when it can't start, instead of quitting silently.
- Connection alerts can no longer be closed, because closing one quietly allowed
  the connection. An alert also stays put when another request arrives, shows
  how many more are waiting, and stays visible when you switch apps.
- A choice you can see in an alert is now the choice that applies. One hour and
  Always wait for system process confirmation, and a Block still applies to the
  connection if its rule hasn't reached the filter yet.
- Alerts say who signed the app, and use Block with ⌘B.
- After any rule change on the Map or in an alert, Rift says what changed in
  plain words, with Undo and View Rule. Undo now works across the app and keeps
  working when you switch pages.
- Fixed Allow leaving a connection blocked when you'd blocked it earlier. Rift
  also checks a rule will really take effect before saving it, and tells you if
  another rule still decides the connection.
- The Map's buttons now say Always Allow and Always Block, and a connection shows
  what will happen from now on as well as what happened then.
- Errors from Map actions stay until you dismiss them, and notices on the Rules
  page no longer hide your rules.
- Modes have plain names that say what happens: Ask Me, Allow and Watch, Block
  Unless Allowed, and Pause Rules. Each one explains itself where you choose it.
- Risky mode changes now warn the same way everywhere, and Resume Rules returns
  you to the mode you paused from.
- Status shows your mode and how many rules and blocklists you have.
- Quitting Rift now tells you what will happen to connections in your mode.

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
