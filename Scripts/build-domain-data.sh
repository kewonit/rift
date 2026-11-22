#!/bin/zsh
# Update Rift's bundled copy of the Public Suffix List (MPL 2.0), which tells
# Rift where a domain stops being a registry suffix like `co.uk`, so domain
# rules never cover a whole suffix. The list asks to be fetched only from
# publicsuffix.org. Rift reads it on the Mac and never fetches it at run time.
#
# usage: Scripts/build-domain-data.sh
# Then commit the file. Its header names the upstream version and commit.

set -euo pipefail

ROOT=${0:A:h:h}
URL=https://publicsuffix.org/list/public_suffix_list.dat
DESTINATION="$ROOT/Resources/DomainData"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL --retry 2 --max-time 120 -A "Rift-domain-data-build (https://github.com/kewonit/rift)" \
  "$URL" -o "$WORK/public_suffix_list.dat"

# A sanity check before replacing the bundled copy.
grep -q '^// ===BEGIN ICANN DOMAINS===$' "$WORK/public_suffix_list.dat"
grep -q '^// ===BEGIN PRIVATE DOMAINS===$' "$WORK/public_suffix_list.dat"
grep -qx 'co.uk' "$WORK/public_suffix_list.dat"
grep -q '^// COMMIT: [0-9a-f]\{40\}$' "$WORK/public_suffix_list.dat"

mkdir -p "$DESTINATION"
install -m 0644 "$WORK/public_suffix_list.dat" "$DESTINATION/public_suffix_list.dat"
shasum -a 256 "$DESTINATION/public_suffix_list.dat"
