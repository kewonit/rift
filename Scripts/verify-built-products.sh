#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
  echo "usage: $0 /path/to/Rift.app" >&2
  exit 64
fi

APP=$1
EXTENSION="$APP/Contents/Library/SystemExtensions/io.rift.firewall.filter.systemextension"
APP_BINARY="$APP/Contents/MacOS/Rift"
EXTENSION_BINARY="$EXTENSION/Contents/MacOS/RiftFilter"
CLI_BINARY="$APP/Contents/Helpers/riftctl"

for item in "$APP_BINARY" "$EXTENSION_BINARY" "$CLI_BINARY"; do
  if [[ ! -f "$item" ]]; then
    echo "missing built binary: $item" >&2
    exit 1
  fi
done

for binary in "$APP_BINARY" "$EXTENSION_BINARY" "$CLI_BINARY"; do
  architectures=(${(z)$(lipo -archs "$binary")})
  if (( ${#architectures} != 1 || ${architectures[(I)arm64]} != 1 )); then
    echo "binary must be arm64-only: $binary (${architectures[*]})" >&2
    exit 1
  fi
done

PRODUCTS=${APP:h}
verify_dsym() {
  local binary=$1
  local symbols=$2
  if [[ ! -d "$symbols" ]]; then
    echo "missing Release symbols: $symbols" >&2
    exit 1
  fi
  local binary_uuid=$(dwarfdump --uuid "$binary" | awk 'NR == 1 { print $2 }')
  local symbol_uuid=$(dwarfdump --uuid "$symbols" | awk 'NR == 1 { print $2 }')
  if [[ -z "$binary_uuid" || "$binary_uuid" != "$symbol_uuid" ]]; then
    echo "dSYM UUID mismatch: $binary -> $symbols" >&2
    exit 1
  fi
}
verify_dsym "$APP_BINARY" "$PRODUCTS/Rift.app.dSYM"
verify_dsym "$EXTENSION_BINARY" "$PRODUCTS/io.rift.firewall.filter.systemextension.dSYM"
verify_dsym "$CLI_BINARY" "$PRODUCTS/riftctl.dSYM"

if ! "$CLI_BINARY" --help >/dev/null; then
  echo "embedded CLI help failed" >&2
  exit 1
fi

python3 - "$APP" "$CLI_BINARY" <<'PY'
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1])
binary = Path(sys.argv[2])
commands = subprocess.run(["otool", "-l", str(binary)], capture_output=True, text=True, check=True).stdout
section = re.search(r"sectname __info_plist\s+segname __TEXT\s+addr \S+\s+size (0x[0-9a-fA-F]+)\s+offset (\d+)", commands)
if section is None:
    raise SystemExit("CLI is missing its embedded connection settings")
size, offset = int(section[1], 16), int(section[2])
info = plistlib.loads(binary.read_bytes()[offset:offset + size])
host = plistlib.loads((app / "Contents/Info.plist").read_bytes())
for key in ["RiftMachServiceName", "RiftTeamIdentifierPrefix"]:
    if key not in info or info[key] != host[key]:
        raise SystemExit(f"CLI connection setting does not match the host: {key}")
PY

if "$CLI_BINARY" rules import /dev/null >/dev/null 2>&1; then
  echo "CLI accepted import without required --dry-run" >&2
  exit 1
fi

if find "$EXTENSION" -type f \
  ! -name Info.plist \
  ! -name embedded.provisionprofile \
  ! -path '*/MacOS/RiftFilter' \
  ! -path '*/_CodeSignature/CodeResources' | grep -q .; then
  echo "unexpected file embedded in system extension" >&2
  exit 1
fi

if find "$APP" -type f \( \
  -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o \
  -iname '*.csv' -o -iname '*.sqlite' -o -iname '*.mmdb' \
\) | grep -q .; then
  echo "app contains a forbidden reference image or location database" >&2
  exit 1
fi

if [[ ! -s "$APP/Contents/Resources/ThirdPartyNotices.txt" ]]; then
  echo "missing third-party notices in app resources" >&2
  exit 1
fi

network_data=(
  'ip-country.bin:5f9ecbf930e99e7ea3577030bc3915f3af8d3064aed3fc8869df286d53db06c1'
  'country-grid.bin:eb16de794d1b218058a80e94de275f0eb64a96c991baf1677bbb3d277a1f7c9a'
  'network-map.json:0c5f5adeed56f93bb112a29a2288fe2ea4731a266c5374c6b2c560519908aec7'
)
for entry in "${network_data[@]}"; do
  file="$APP/Contents/Resources/${entry%%:*}"
  if [[ ! -f "$file" || "$(shasum -a 256 "$file" | awk '{print $1}')" != "${entry#*:}" ]]; then
    echo "missing or changed network map data: ${entry%%:*}" >&2
    exit 1
  fi
done

for binary in "$EXTENSION_BINARY" "$CLI_BINARY"; do
  dependencies=$(otool -L "$binary" | awk '/compatibility version/ {print $1}')
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/*|/usr/lib/*) ;;
      *)
        echo "privileged/CLI binary has non-system dependency: $binary -> $dependency" >&2
        exit 1
        ;;
    esac
  done <<< "$dependencies"
done

rpaths=$(otool -l "$EXTENSION_BINARY" | awk '
  previous == "LC_RPATH" && $1 == "path" { print $2 }
  $1 == "cmd" { previous = $2 }
')
while IFS= read -r rpath; do
  [[ -z "$rpath" || "$rpath" == "/usr/lib/swift" ]] && continue
  echo "extension has escaping runpath: $rpath" >&2
  exit 1
done <<< "$rpaths"

if ! /usr/libexec/PlistBuddy -c 'Print :NetworkExtension:NEProviderClasses:com.apple.networkextension.filter-data' \
  "$EXTENSION/Contents/Info.plist" | grep -qx 'RiftFilter.FilterDataProvider'; then
  echo "filter provider class is not configured" >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' \
  "$APP/Contents/Info.plist" | grep -qx 'true'; then
  echo "host app does not prohibit duplicate Launch Services instances" >&2
  exit 1
fi

for info_plist in "$APP/Contents/Info.plist" "$EXTENSION/Contents/Info.plist"; do
  if [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :NSSystemExtensionUsageDescription' \
    "$info_plist" 2>/dev/null)" ]]; then
    echo "missing system-extension usage description: $info_plist" >&2
    exit 1
  fi
done

fixture_canaries=(
  'RIFT_FIXTURE_DRIVER'
  '--ui-fixture'
  'RIFT_UI_FIXTURE_ONLY_7F4C2A91'
  'RIFT_UI_FIXTURE_ARTWORK_ONLY_5C8E1D42'
  'The UI fixture cannot create'
  'MonitorFixtureData'
  'startFixtureDriverIfRequested'
)
for binary in "$APP_BINARY" "$EXTENSION_BINARY" "$CLI_BINARY"; do
  for canary in "${fixture_canaries[@]}"; do
    if strings "$binary" | grep -F -- "$canary" >/dev/null; then
      echo "Release binary contains Debug-only fixture content: $binary -> $canary" >&2
      exit 1
    fi
  done
done

if otool -L "$EXTENSION_BINARY" | grep -Eiq '(GRDB|libsqlite)'; then
  echo "system extension unexpectedly links a database library" >&2
  exit 1
fi

echo "PASS: built arm64-only app, extension, and CLI structure"
