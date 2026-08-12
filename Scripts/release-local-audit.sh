#!/bin/zsh

set -euo pipefail

ROOT=${0:A:h:h}

plutil -lint "$ROOT/Abyss.xcodeproj/project.pbxproj" "$ROOT"/Configuration/*.plist \
  "$ROOT"/Configuration/*.entitlements
jq empty "$ROOT/docs/release/sbom.spdx.json"

for required in CHANGELOG.md CONTRIBUTING.md LICENSE PRIVACY.md README.md \
  SECURITY.md THIRD_PARTY_NOTICES.md docs/release/reproducibility.md \
  .github/workflows/nonfiltering.yml; do
  if [[ ! -s "$ROOT/$required" ]]; then
    print -u2 "missing source-release material: $required"
    exit 1
  fi
done

if ! rg -q 'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd' \
  "$ROOT/.github/workflows/nonfiltering.yml"; then
  print -u2 "GitHub checkout action is not pinned to the reviewed revision"
  exit 1
fi

control_inventory=$'grdb.swift\thttps://github.com/groue/GRDB.swift.git\t7.10.0\t36e30a6f1ef10e4194f6af0cff90888526f0c115'
workspace_inventory=$'grdb.swift\thttps://github.com/groue/GRDB.swift.git\t7.10.0\t36e30a6f1ef10e4194f6af0cff90888526f0c115\nswift-argument-parser\thttps://github.com/apple/swift-argument-parser.git\t1.8.2\t6a52f3251125d74daf04fcbd5e6f08a75d074382'
verify_lock() {
  local lock_path=$1
  local expected=$2
  local actual=$(jq -r '.pins | sort_by(.identity)[] | [.identity, .location, .state.version, .state.revision] | @tsv' "$lock_path")
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "dependency lock inventory is not the reviewed exact set: $lock_path"
    exit 1
  fi
}
verify_lock "$ROOT/Packages/AbyssControl/Package.resolved" "$control_inventory"
verify_lock "$ROOT/Abyss.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$workspace_inventory"
verify_lock "$ROOT/Abyss.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" "$workspace_inventory"

for pin in 36e30a6f1ef10e4194f6af0cff90888526f0c115 \
  6a52f3251125d74daf04fcbd5e6f08a75d074382; do
  if ! rg -q "$pin" "$ROOT/Abyss.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    || ! rg -q "$pin" "$ROOT/docs/release/sbom.spdx.json" \
    || ! rg -q "$pin" "$ROOT/THIRD_PARTY_NOTICES.md"; then
    print -u2 "dependency inventory is inconsistent for revision: $pin"
    exit 1
  fi
done

oversized=$(find "$ROOT/App" "$ROOT/Extension" "$ROOT/CLI" "$ROOT/Packages" \
  -path '*/.build*' -prune -o \
  \( -path '*/Sources/*' -o -path "$ROOT/App/*" -o -path "$ROOT/Extension/*" -o -path "$ROOT/CLI/*" \) \
  -name '*.swift' -type f -print0 | xargs -0 wc -l | awk '$1 > 500 && $2 != "total" {print}')
if [[ -n "$oversized" ]]; then
  print -u2 "production files over 500 lines:"
  print -u2 "$oversized"
  exit 1
fi

if rg -n --hidden --glob '!.git/**' --glob '!inspiration_images/**' \
  --glob '!Scripts/release-local-audit.sh' \
  '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[baprs]-[A-Za-z0-9-]{20,}|notarytool.{0,80}(--password|password=))' \
  "$ROOT"; then
  print -u2 "possible secret material found"
  exit 1
fi

"$ROOT/Scripts/test-nonfiltering.sh"
"$ROOT/Scripts/publication-preflight.sh"

echo "PASS: local Apple-silicon release audit"
