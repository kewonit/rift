#!/bin/zsh
# Rebuild Rift's bundled network map data from pinned public sources.
# Sources: ip-location-db server-country (PDDL 1.0), OpenStreetMap undersea
# cables (ODbL 1.0), and Natural Earth admin-0 countries (public domain).

set -euo pipefail

ROOT=${0:A:h:h}
IP_DB_COMMIT=6953822901329539b856e9cf48aa95f2de579e87
IP_DB_IPV4_SHA256=90b82b68a214b220b91a2c5fbdab53c5d250e33966e2af719a011128886bdc60
IP_DB_IPV6_SHA256=17addb52c58c7fa4b609a0499d81f71eb9bbe08d2273a92025b87f637de60450
NATURAL_EARTH_URL=https://naciscdn.org/naturalearth/50m/cultural/ne_50m_admin_0_countries.zip
NATURAL_EARTH_SHA256=5fed433373581fa648920435f937d95f2d3c0200e067409c6478dcdf1b853139
OSM_SNAPSHOT=2026-10-25T00:00:00Z
OSM_ELEMENTS_SHA256=9d74410aa40310bec708255b5d39e0ca4d956feed328b1aaedbedf149e73750a
OSM_QUERY="[out:json][timeout:300][date:\"$OSM_SNAPSHOT\"];(way[\"communication\"=\"line\"][\"submarine\"=\"yes\"];way[\"communication\"=\"line\"][\"location\"=\"underwater\"];way[\"telecom\"=\"line\"][\"location\"=\"underwater\"];way[\"telecom\"=\"line\"][\"submarine\"=\"yes\"];way[\"seamark:type\"=\"cable_submarine\"][\"seamark:cable_submarine:category\"~\"telephone|fibre_optic|optical|telegraph|telecommunication\"];);out tags geom;"
USER_AGENT="Rift-network-data-build (https://github.com/kewonit/rift)"
DESTINATION="$ROOT/Resources/NetworkData"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() {
  curl -fsSL --retry 2 --max-time 400 -A "$USER_AGENT" "$@"
}

for family in ipv4 ipv6; do
  fetch "https://raw.githubusercontent.com/sapics/ip-location-db/$IP_DB_COMMIT/server-country/server-country-$family.csv" \
    -o "$WORK/server-country-$family.csv"
done
echo "$IP_DB_IPV4_SHA256  $WORK/server-country-ipv4.csv" | shasum -a 256 -c -
echo "$IP_DB_IPV6_SHA256  $WORK/server-country-ipv6.csv" | shasum -a 256 -c -

fetch "$NATURAL_EARTH_URL" -o "$WORK/countries.zip"
echo "$NATURAL_EARTH_SHA256  $WORK/countries.zip" | shasum -a 256 -c -

fetch --data-urlencode "data=$OSM_QUERY" https://overpass-api.de/api/interpreter -o "$WORK/osm.json"

python3 -I "$ROOT/Scripts/build-network-data.py" \
  --countries-zip "$WORK/countries.zip" \
  --ipv4-csv "$WORK/server-country-ipv4.csv" \
  --ipv6-csv "$WORK/server-country-ipv6.csv" \
  --osm-json "$WORK/osm.json" \
  --osm-elements-sha256 "$OSM_ELEMENTS_SHA256" \
  --source-label "ip-location-db server-country $IP_DB_COMMIT; OpenStreetMap $OSM_SNAPSHOT; Natural Earth 50m" \
  --output "$WORK/out"

mkdir -p "$DESTINATION"
for file in ip-country.bin country-grid.bin network-map.json; do
  install -m 0644 "$WORK/out/$file" "$DESTINATION/$file"
done
shasum -a 256 "$DESTINATION"/*
