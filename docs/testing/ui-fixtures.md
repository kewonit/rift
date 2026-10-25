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
- `burst`
- `denied`
- `unresolved`
- `missing-origin`
- `rules-failure`
- `health-setup`
- `alert-delivery-failure`

For example:

```sh
open -n .build/DerivedData/Build/Products/Debug/Rift.app --args \
  --ui-fixture --ui-fixture-state missing-origin
```

Use `--ui-fixture --ui-fixture-status-menu` to render the menu-bar dashboard in
a Debug window without changing the real macOS status area.

The Release verifier rejects fixture flags and their canaries in distributable
products.
