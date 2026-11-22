# Changelog

The changelog records notable user-visible changes.

## Unreleased

- A connection alert now offers a lasting rule for the whole domain by
  default, so the same app doesn't ask again for the next name under it.
  Connections with no name, and incoming ones, still default to the exact
  destination. Alert defaults start at "As last time", which follows your most
  recent lasting answer; choosing a fixed default in Settings › Alerts keeps it.
  Before, alerts defaulted to Once for one host and port.
- Alerts and the Alert Defaults setting add 15 minutes, 1 day and 1 week.
- An alert with a warning, such as for unsigned code or a look-alike name, is
  titled "Check this connection" and tinted, and Return no longer allows it:
  click Allow or press ⌘A. The one-second guard against keys typed for
  another window now covers ⌘A and ⌘B too.
- Exported configurations now include blocklist subscription addresses,
  Settings › Networks, and alert settings such as "Block connections I don't
  answer", and Import Configuration restores them. Before, a restore brought
  back a subscribed blocklist's entries but not its subscription, and lost
  every network's profile choice. Undo Restore puts the previous settings
  back. Configurations exported by this version can't be imported by earlier
  ones.
- `riftctl status` starts with the mode, the active profile and the filter's
  state as Rift's Status page shows them, and `--json` adds them under `app`.
  It doesn't open Rift for this; when Rift isn't running, it says so.
- With history on, Settings › History shows how many outgoing connections in
  the last 7 days reached Rift with only an IP address, which rules for names
  and domain blocklists can't match. Diagnostics include the same two counts.
- Setup now keeps 7 days of connection history when you choose Allow and
  Watch, so there is something to review, and says so; you can turn it off
  there or in Settings › History. Before, setup left history off, which kept
  only 10 connections for five minutes. Choosing Ask Me offers "Allow Apple
  system services", which adds the macOS Services group before the first
  alert.
- A Review sheet lists apps that connected with no rule over the last 7 days,
  and alerts nobody answered, each with one-click Allow and Block and Undo.
  The Map shows a banner and the menu-bar panel a line while something is
  left; "Not Now" hides an app until it connects somewhere new. After a day
  in Allow and Watch, Rift suggests a review once, and when nothing is left
  it offers Ask Me.
- Notifications about a connection no rule decided, including alerts nobody
  answered, have Allow and Block buttons that make a lasting rule for its
  domain, with Undo in Rift. A new network's notification offers "Use Current
  Profile Here" and "Choose…", which opens Settings › Networks.
- Blocklists now block listed destinations for every account on the Mac,
  including processes running as root. Before, they covered only your account.
- While you aren't at the console, such as before login, app rules for your
  account and root now apply, and Block Unless Allowed keeps blocking
  connections with no rule. Before, Rift couldn't identify the app, so these
  connections were allowed.
- IP blocklists block incoming connections from listed addresses, and "Local
  network" matches an incoming connection only when the peer is on your local
  network. Before, both checked this Mac's own address. To let one listed
  address in, turn off its blocklist entry; an Allow rule would open the
  service to every listed address, so Rift won't make one.
- Choosing One hour on the Map no longer turns a permanent rule into a
  temporary one. Rift says when a permanent rule does the opposite.
- Removing a group or profile and keeping its rules no longer turns on rules
  that were off: rules from a turned-off group or an inactive profile stay off.
- `riftctl profiles activate` refuses a switch that weakens protection or that
  Rift would ask you to confirm, including one that turns off a profile's
  blocking rules. Make those switches in Rift.
- Internationalized names, shown in their `xn--` form, can be blocked by name
  and imported from blocklists. Before, Rift ignored them.
- Settings and the Block Unless Allowed confirmation now say that Rift filters
  TCP and UDP only.
- In a connection alert, Return allows and Esc blocks. Keys pressed in the
  first second after an alert appears are ignored. ⌘A and ⌘B still work.
- Alerts offer Five minutes, and a rule can cover this destination on any port.
  Settings › Alerts can preselect either.
- Alerts warn when the app or its helper isn't signed, is signed only by
  itself, uses a certificate Apple didn't issue, or runs from a temporary copy
  macOS made, and when a name uses international letters.
- Alert Details and the Map inspector say who signed the app and list the rules
  that apply to the connection.
- Allow and Block on the Map offer Five minutes.
- Temporary rules count down in the inspector and can be made permanent, even
  after they've expired.
- The Rules page has Expired, Incoming, Unused and Redundant lists. Redundant
  shows rules another rule already covers, so deleting them changes nothing.
  Rules can also be sorted by precedence, the order the filter ranks them in.
- Map search understands `domain:`, `proto:`, `country:` and
  `decision:timedout`. The search field's tooltip lists every filter.
- From Now (⌘K) hides earlier connections. A chip shows them again.
- Connection rows have Copy and Copy Hostname, and Hide Connections Like
  This, which adds a Hide rule so that app's connections to that host stay out
  of the Map and history while still being filtered.
- Window › Float on Top keeps Rift above other windows.
- Notifications have separate switches for blocked connections, connections no
  rule decided, and Notify rules, with an optional sound for Notify rules.
- Blocklists read Adblock-style `||name^` lines and `;` comments. Adblock
  rules Rift can't apply are skipped. Before, an element-hiding line such as `example.com##.ad` blocked
  example.com, and other Adblock rules stopped the import.
- For incoming connections, the map, the Country column, the Network filter and
  `country:` search use the remote peer. Before, they used this Mac's own
  address, so incoming connections from the internet showed as local and had
  no country. `ip:` also finds an incoming connection by its peer's address.
- The connections list can be grouped by country.
- The connections list can show a log instead: one line per connection,
  newest first, under day headings, with the same search and filters.
- With nothing selected, the Map inspector can show a summary of the
  connections in the list: counts, data sent and received, and the most active
  apps, hostnames and countries. View › Show Inspector (⌥⌘I) turns it on.
- The Rules page can export the selected rules to a file and import rules from
  one. Importing adds rules without replacing any; rules you already have are
  skipped, and imported rules are marked unreviewed. Blocklist exceptions and
  rules for system processes arrive turned off until you check them. Restore
  in Settings won't open a file of selected rules, so it can't replace your
  configuration with them. Older versions of Rift can't read these files.
- Edit Rules… changes the action, protocol, port or notes of several rules at
  once, and can be undone.
- The menu bar panel lists recently blocked connections, with Allow for 5
  Minutes, and temporary rules that are still running, with the time left,
  Make Permanent and Remove. Its recent apps can be allowed or blocked for 5
  minutes from their context menu.
- A connection alert can be minimized to a small bar that keeps counting down,
  and another waiting connection can be answered first. Settings › Alerts can
  show alerts minimized.
- Rules can cover a domain and its subdomains. In the rule editor, turn on
  Include subdomains or type `*.name`. Alerts and the Map offer "example.com
  and its subdomains", taken from the part of the name someone registered, and
  Settings › Alerts can preselect it. Rift won't make a domain rule for a
  suffix anyone can register under, like `co.uk`; it checks a copy of the
  Public Suffix List that ships with the app.
- When two domain rules match a connection, the more specific one wins: a
  Block on ads.example.com beats an Allow on example.com. Before, the broader
  domain won.
- In a blocklist, a plain list of names, `*.name` and `||name^` lines now block
  every name under each one; hosts files still block the exact names they
  list. Lists imported earlier match exact names until you import them again.
  Check Entry lists every entry that blocks a name, including one that covers
  it as a subdomain.
- Names with international letters can be typed as they're written; Rift
  stores and shows them in their `xn--` form.
- The connections list can be grouped by domain.
- Import Rules on the Rules page reads `.lsrules` rule group files. Each rule's
  app is found on this Mac by its path or code ID, and the rules go into a
  group named after the file, unreviewed. Rules Rift can't apply as written,
  such as ones for ICMP, DNS servers, port lists or another account, are
  skipped and counted rather than changed.
- Settings › Blocklists can import a `.lsrules` file that only blocks
  destinations, as a blocklist.
- A blocklist can be a subscription to a web address you enter. Rift
  downloads it over HTTPS, checks for a new version once a day while it's
  running, and keeps the list's on or off state and the entries you turned
  off. Update Now checks right away. Rift adds no list by itself.
- Alert details and the Map inspector say what common macOS services do, from
  notes that ship with Rift, and offer Search the Web, which opens your
  browser with a search for the app and destination.
- The Rules sidebar's Add menu can add a macOS Services group, which lets
  Apple's own system services reach Apple's servers, so Ask and Block Unless
  Allowed don't interrupt iCloud, updates or certificate checks. Nothing is
  added at setup, and the group's rules can be edited, turned off or deleted
  like any others.
- Settings › Networks can switch profiles by network. Rift remembers the
  networks the Mac joins, so you can choose a profile for each and for new
  ones, and tells you when it switches or finds a new network. It recognizes
  a network by its router's address, or by its Wi-Fi name if you allow it;
  macOS then asks for Location Services permission, which it requires to read
  Wi-Fi names. Rift switches on its own only to a profile at least as strict
  as the current one; for a less strict one it notifies you instead, because
  anyone can name a network after yours.
- Settings › Alerts can block connections you don't answer: Rift answers Block
  just before the alert times out, and the countdown says so. When Rift isn't
  open, or before you log in, connections nobody can answer are still allowed.

## 0.4.0

The first signed and notarized download of Rift. These notes list the changes
since the unpublished 0.3.0 source.

- Rift has a new window. One sidebar holds Map, Status and your rules, filters,
  profiles, groups and blocklists. The Activity page is part of the Map page.
- The Map page shows the map above a slim timeline and a table of connections.
  ⌘T hides the map to give the table the whole window.
- The map is drawn like a chart: faint cables, thin routes and small markers.
  It opens on This Mac and the places your connections go, and selecting a
  connection fits its route.
- The inspector appears when you select a connection, and search sits above
  each table.
- Rules show on one line, and the rule inspector matches the connection one.
- A newer Rift updates its network filter by itself when it opens, instead of
  asking you to find a button.
- `rift://` links now open Rift. The app never told macOS it handles them.
- Rift updates itself. It checks GitHub once a day and installs a new version
  only when it's signed by Rift's developer, then updates its network filter.
  Every release is also notarized by Apple. Turn this off in Settings › General, or use Check for
  Updates… in the Rift menu.
- App helpers, such as Chrome's, show their app's name and icon.
- Sidebar icons are monochrome.
- One timeline shows traffic or decisions for the chosen time range.
- The menu-bar panel was rebuilt with a mode menu, recent apps with their
  decisions, and standard menu rows.
- Rift has a new app icon: two rings split along a fault.
- Lists show verified app names instead of signing identifiers where Rift can
  match the installed app.
- The map does less work while it's open: route animation, map updates and
  app-icon lookups were reworked, and launch no longer waits for the databases
  to open.
- Rift releases the map 30 seconds after its window is hidden, to free its
  memory while it runs in the background.
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
- Setup now ends with one plain question about how Rift should behave, with a
  recommended answer, and offers Open at Login and connection history. Choosing
  Ask Me also turns on Open at Login, because Rift has to be open to ask.
- Before setup is finished, Rift says so instead of failing. The Map holds its
  location prompt until the filter is on, empty lists explain why they're empty,
  and mode and rule controls say to finish setup first.
- The timeline has a Keep History button when history is off.
- You can now block or allow any app or site from the Map, including apps with
  several destinations. You choose what the rule covers and for how long before
  it's made, and blocking a site now covers every port by default.
- The connection list holds still while you point at it, so a click can't land
  on the wrong row.
- The inspector names the rule that decided a connection and opens it directly.
- Clicking a country on the map now narrows the list, table and timeline to it,
  with a chip to clear it. The map keeps showing the other countries.
- Selection stays on what you picked when the list refreshes, and a connection
  opened from elsewhere reveals itself in the list.
- Search finds the app and country names shown on screen, and sorting by name
  uses them too.
- The inspector shows numbers for the selected app, with its destinations, and
  apps open straight to their destinations.
- Switching pages keeps your search, filters and selection.
- Empty lists say whether nothing happened or your filters hid it, with a way to
  clear them. Rows that are partly blocked now say so.
- The map legend explains blocked markers and says when it leaves connections
  out.
- Looking at the past is now obvious: Rift shows the dates, a Viewing past
  activity label with Back to Live, and stops the map's flow dots.
- Time ranges say what they mean, such as This Hour and Today. The timeline has
  time labels, and the Decisions chart now follows your search and filters.
- On the Rules page, turn a rule on or off with a checkbox, double-click to edit
  it, and use the buttons in the inspector, with no need to right-click.
- Each rule now shows whether it's really in use, such as Active, Off, Other
  profile, Group off, Expired or Waiting for filter.
- The rule editor leads with what most people need, and keeps the rest under
  Advanced. It shows app names, lets you choose any app, and shows problems
  beside Save.
- Profiles, Groups and Blocklists are always visible on the Rules page, with a
  line explaining each. The page updates when rules change elsewhere.
- History settings now apply as you change them, and deleting rules or removing
  a blocklist from Settings asks first, as it does on the Rules page.
- Notifications say only what's known, the toggle says what it really does, and
  clicking a notification opens the connection on the Map.
- If Rift can't read your rules, Status now offers the newest working backup in
  one click, as well as importing a file or starting fresh.
- Rift now uses one set of plain words everywhere, such as Block, App and On, and
  its text no longer mentions pages that have gone.
- Everything on the Map has a menu item and shortcut, including the table,
  inspector, timeline, search and Allow and Block. Undo for rule changes works
  from anywhere with ⌥⌘Z.
- With VoiceOver, connection rows offer Allow, Block and Show Rule, and new
  alerts and the results of rule changes are announced.

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

## 0.1.0 (pre-release)

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
