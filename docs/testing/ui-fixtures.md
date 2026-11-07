# UI fixtures

Rift's preview fixtures are compiled only in Debug builds. They use fixed sample
data and never connect to the system extension or change the Mac. Build the
`Rift-Dev` scheme, then launch the app with `--ui-fixture`:

```sh
open -n .build/DerivedData/Build/Products/Debug/Rift.app --args --ui-fixture
```

Add `--ui-fixture-state <state>` to review a specific state:

- `live`
- `empty`
- `burst` (streams four new connections a second, for profiling)
- `denied`
- `unresolved`
- `missing-origin`
- `rules-failure`
- `health-setup`
- `alert-delivery-failure`

For example:

```sh
open -n .build/DerivedData/Build/Products/Debug/Rift.app --args \
  --ui-fixture-state missing-origin --ui-fixture
```

Use `--ui-fixture --ui-fixture-status-menu` to render the menu-bar dashboard in
a Debug window without changing the real macOS status area.

Other preview options:

- `--ui-fixture-page rules` or `--ui-fixture-page status` opens that page.
- `--ui-fixture-table` opens the Map page with the connection table expanded.
- `--ui-fixture-alert` shows a connection alert for a sample request.
- `--ui-fixture-settings` opens the Settings window.
- `--ui-fixture-dark` uses the dark appearance.
- `--ui-fixture-float` keeps preview windows above other apps without taking
  focus, so screenshots of the map render.
- `--ui-fixture-hide` hides the app a few seconds after launch, to measure
  background cost.
- `--ui-fixture-alert-panel` shows the real alert panel with a 30 second
  deadline, and `--ui-fixture-alert-queue` shows it with two more waiting.
- `--ui-fixture-apply-rule block` blocks the first connection through the real
  action path, `undo` also undoes it, and `chooser` stops at the scope chooser.
- `--ui-fixture-country <code>` starts the Map narrowed to one country, such as
  `JP`, as if its marker was clicked.
- `--ui-fixture-status <state>` shows one status on Status, the menu-bar panel
  and the Map instead of Preview. The states are `cannot-filter`, `unreadable`,
  `setup`, `installing`, `approval`, `off`, `problem`, `connecting`,
  `unreachable`, `allowing`, `at-risk`, `not-current`, `waiting`, `watch`,
  `ask`, `block`, `paused` and `setup-question`, which also shows the last step
  of setup.

macOS reads launch arguments as `-key value` pairs, and treats a leftover word
as a document to open, which stops the window from appearing. Put options that
take a value first, for example:

```sh
open -n .build/DerivedData/Build/Products/Debug/Rift.app --args \
  -ApplePersistenceIgnoreState YES --ui-fixture-state burst --ui-fixture --ui-fixture-dark
```

`-ApplePersistenceIgnoreState YES` stops macOS from restoring a previous
preview's window state.

The Release verifier rejects fixture flags and their canaries in distributable
products.
