# Privacy

Rift makes firewall decisions on the Mac. It does not use analytics, an
advertising SDK, a telemetry service, automatic diagnostics upload, or
packet-payload capture. It doesn't send destination IP addresses to any
service. Rift subscribes to no blocklist or rule group on its own; it downloads
one only from a web address you enter, as described under
[Subscriptions](#subscriptions). It checks GitHub once a day
for software updates, as described under [Update checks](#update-checks).

## Data kept on the Mac

- The signed app's local container stores editable configuration: rules,
  profiles, groups, blocklist metadata, app and process identity conditions,
  notes, and local settings.
- The system extension's separate, root-owned container stores only the
  validated compiled current and previous policies, ownership state, bounded
  expiry metadata, and recovery indexes. It does not store connection history.
- Setup offers to keep connection history for 7 days, so you can review what
  connected, and suggests it when you choose Allow and Watch. If you turn it
  off, Rift saves no connection history. Optional activity then keeps at
  most 10 recent connections in memory for five minutes while the Map page is
  visible, or five when only the menu panel is open. Collection stops and
  these buffers are released when all activity views are hidden, minimized,
  fully obscured, or closed. Rules and prompt handling remain active.
- Persistent history keeps up to 50,000 flows for the number of days you
  choose in Settings › History, from 1 to 30: 7 when turned on in setup.
  It contains bounded decision metadata and close-reported byte totals when
  macOS supplies them. The metadata includes the process ID and the path of
  the program that connected, which can contain your account name. A JSON
  history export includes them; diagnostics never do. Existing history
  preferences are preserved. Turning
  recording off keeps old logs; deleting them requires Clear History.
  Privacy-hidden decisions do not enter visible history or aggregates.
- Rule-use counters are separate from connection history. Users can clear them
  separately. New usage is recorded only while persistent history is enabled.
- Whether the configuration is locked is saved in the app's local preferences.
  Unlocking uses the Touch ID or password prompt macOS shows; Rift never sees
  your fingerprint or password.
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

To show which undersea cables a connection likely uses, Rift looks up the
country of each destination address in a table bundled with the app. The lookup
happens on the Mac; Rift sends the address nowhere. Rift then estimates a path
from the location you placed to that country across the bundled cable map. The
country can be wrong for VPNs, relays, and content delivery networks, and the
path is an estimate, not the route your data actually takes. Countries and
paths are shown only while the map is open and aren't saved.

## Switching profiles by network

**Settings › Networks** is off until you turn it on. Rift then remembers the
networks the Mac joins, on this Mac only, so you can choose a profile for each.
It recognizes a network by its router's address. If you also turn on
**Recognize Wi-Fi networks by name**, macOS asks whether Rift may use Location
Services, because macOS lets apps read Wi-Fi names only with that permission.
Rift reads only the network's name and never asks for the Mac's location.

## Subscriptions

If you subscribe to a blocklist in **Settings › Blocklists**, Rift downloads it
from the address you entered right away, then checks for a new version while
Rift is running as often as you choose for that list (every hour, day or week,
or only when you ask; daily unless you change it), and when you choose
**Update Now** or **Update All Subscriptions**.

If you subscribe to a rule group with **Subscribe to Rule Group…** on the Rules
page, Rift downloads the `.lsrules` file from the address you entered, shows
what it would add, and adds nothing until you confirm. It then checks the file
as often as you choose for that group, the same way as a blocklist, and when
you choose **Update Now**. Unless you turn it off for that group, allow rules
that arrive in an update stay off until you turn them on.

Rift downloads only over HTTPS, sends no cookies and no details about the Mac,
and identifies itself only as "Rift". The server sees your IP address and when
Rift checks, as with any download. Removing the blocklist or rule group stops
the checks. Rift suggests no lists or groups and never adds a subscription by
itself.

## Explaining a connection

Alert details and the Map inspector describe common macOS services from notes
that ship inside Rift, so nothing is looked up. For an app signed with a
Developer ID or from the Mac App Store, they also show what the app's developer
says a connection is for, and what blocking it would break, from the Internet
Access Policy file the developer ships inside the app. Rift reads that file
from the app on disk, uses it only when the app's signature covers it, and
keeps it in memory only. When history is on and has been recording for at
least a day, an alert can also say it's the first time the app has connected
to a domain; that comes from your history on this Mac. **Search the Web** opens
your browser with a DuckDuckGo search for the app's identifier and the
destination. Rift sends nothing itself, and the search happens only when you
click it.

## Update checks

Rift checks for a new version once a day by downloading a small feed from
GitHub. GitHub sees your IP address and Rift's version in that request, as with
any download. Rift sends no connections, rules, history, or details about the
Mac. Turn off **Check for updates automatically** in **Settings › General** to
stop the daily check; **Check for Updates…** in the Rift menu still works.

An update installs only when it's signed with Rift's update key and by the same
Apple Developer ID team as the copy you have. Every release is also notarized
by Apple.

## Exports and sharing

Configuration archives exclude history, counters, machine identifiers, policy
lineage and generation, and signing material. They include blocklist and rule
group subscription addresses, alert settings, and **Settings › Networks**, so a
restore brings those back too. When profile switching by network is on, that
means the names of remembered networks, which can include Wi-Fi names and
router addresses. Rules exported as a rule set or as a `.lsrules` file contain
the apps' code identifiers or executable paths, destinations, and notes.
Diagnostics are created only after
a user action. They preview their contents, default to aggregate and redacted
state, and are never uploaded automatically. Optional recent activity and rule
summaries use fresh pseudonyms that are linkable only within that bundle.

`riftctl` can show status and profiles and save redacted diagnostics. It can
export connection history only after you turn on **Allow access from
Terminal** in **Settings › Advanced**, because any app running as you can run
`riftctl`.

Exported files are outside Rift's control. Review them before sharing. Use a
secure channel. Do not include private traffic data or Apple signing credentials
in a public issue.

## Removal and recovery

In-app extension removal keeps editable configuration and history unless the
user clears them separately. Deleting the app without completing removal can
leave the approved system extension and its last durable policy active. Follow
the recovery steps in [runtime limitations and recovery](docs/release/runtime-limitations.md).

This page describes Rift 0.4.0.
