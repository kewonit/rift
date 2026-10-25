#!/usr/bin/env python3
"""Build Rift's bundled network map data from pinned public sources.

Outputs (all deterministic for the same inputs):
  ip-country.bin     IPv4/IPv6 range starts -> ISO country code (deflate)
  country-grid.bin   0.25-degree land/country grid, run-length encoded (deflate)
  network-map.json   country label points, cable nodes, cable segments, land links
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import heapq
import ipaddress
import json
import math
import struct
import zipfile
import zlib
from pathlib import Path

GRID_STEP = 0.25
GRID_WIDTH = int(360 / GRID_STEP)
GRID_HEIGHT = int(180 / GRID_STEP)
MIN_SEGMENT_KM = 5.0
NODE_MERGE_KM = 15.0
LANDING_SEARCH_CELLS = 3
OSM_SIMPLIFY_DEGREES = 0.02
ROUTE_SIMPLIFY_DEGREES = 0.2
LAND_LINK_MAX_KM = 1200.0
SAME_COUNTRY_LINK_MAX_KM = 800.0
LAND_LINK_MIN_LAND_SHARE = 0.75

# Main sea routes that OpenStreetMap doesn't map yet. Each hub is a real coastal
# cable landing area. Paths between hubs are drawn by a sea-routing search, so
# they are approximate.
HUBS = {
    "US-OR": ("Oregon", 45.20, -123.97, "US"),
    "US-LA": ("Los Angeles", 33.86, -118.40, "US"),
    "US-HI": ("Oahu", 21.35, -158.13, "US"),
    "US-FL": ("Boca Raton", 26.37, -80.07, "US"),
    "US-VA": ("Virginia Beach", 36.85, -75.97, "US"),
    "US-NJ": ("New Jersey", 40.15, -74.03, "US"),
    "GU": ("Guam", 13.47, 144.75, "GU"),
    "JP-CH": ("Chiba", 34.95, 139.95, "JP"),
    "JP-SH": ("Shima", 34.33, 136.83, "JP"),
    "KR": ("Busan", 35.10, 129.04, "KR"),
    "CN-SH": ("Shanghai", 31.05, 121.95, "CN"),
    "TW": ("Toucheng", 24.85, 121.83, "TW"),
    "HK": ("Hong Kong", 22.25, 114.25, "HK"),
    "PH": ("Batangas", 13.75, 121.05, "PH"),
    "VN": ("Vung Tau", 10.35, 107.08, "VN"),
    "SG": ("Singapore", 1.30, 103.98, "SG"),
    "ID": ("Jakarta", -6.10, 106.80, "ID"),
    "AU-PE": ("Perth", -31.95, 115.75, "AU"),
    "AU-SY": ("Sydney", -33.92, 151.26, "AU"),
    "NZ": ("Auckland", -36.85, 174.78, "NZ"),
    "FJ": ("Suva", -18.14, 178.44, "FJ"),
    "IN-CH": ("Chennai", 13.08, 80.29, "IN"),
    "IN-MU": ("Mumbai", 19.08, 72.82, "IN"),
    "LK": ("Colombo", 6.93, 79.84, "LK"),
    "PK": ("Karachi", 24.82, 66.98, "PK"),
    "OM": ("Barka", 23.70, 57.89, "OM"),
    "AE": ("Fujairah", 25.12, 56.36, "AE"),
    "DJ": ("Djibouti", 11.60, 43.15, "DJ"),
    "SA": ("Jeddah", 21.50, 39.17, "SA"),
    "EG-ZA": ("Zafarana", 29.12, 32.65, "EG"),
    "EG-AL": ("Alexandria", 31.20, 29.90, "EG"),
    "IT": ("Catania", 37.50, 15.09, "IT"),
    "FR": ("Marseille", 43.30, 5.36, "FR"),
    "PT": ("Sesimbra", 38.44, -9.10, "PT"),
    "ES-CN": ("Canary Islands", 28.10, -15.42, "ES"),
    "SN": ("Dakar", 14.69, -17.45, "SN"),
    "CI": ("Abidjan", 5.30, -4.01, "CI"),
    "GH": ("Accra", 5.55, -0.20, "GH"),
    "NG": ("Lagos", 6.43, 3.40, "NG"),
    "AO": ("Luanda", -8.82, 13.23, "AO"),
    "NA": ("Swakopmund", -22.68, 14.53, "NA"),
    "ZA-CT": ("Cape Town", -33.92, 18.42, "ZA"),
    "ZA-DU": ("Durban", -29.86, 31.03, "ZA"),
    "MZ": ("Maputo", -25.97, 32.57, "MZ"),
    "TZ": ("Dar es Salaam", -6.82, 39.29, "TZ"),
    "KE": ("Mombasa", -4.04, 39.67, "KE"),
    "BR-FO": ("Fortaleza", -3.72, -38.52, "BR"),
    "BR-RJ": ("Rio de Janeiro", -22.97, -43.18, "BR"),
    "AR": ("Las Toninas", -36.49, -56.70, "AR"),
    "CL": ("Valparaiso", -33.04, -71.63, "CL"),
    "PE": ("Lurin", -12.28, -76.87, "PE"),
    "PA-PAC": ("Panama City", 8.95, -79.53, "PA"),
    "PA-CAR": ("Colon", 9.36, -79.90, "PA"),
    "CO": ("Cartagena", 10.39, -75.51, "CO"),
    "PR": ("San Juan", 18.47, -66.11, "PR"),
}

ROUTES = [
    ("Trans-Pacific route (US-Japan)", ["US-OR", "JP-CH"]),
    ("Trans-Pacific route (US-Japan, south)", ["US-LA", "JP-SH"]),
    ("US-Hawaii-Guam-Philippines route", ["US-LA", "US-HI", "GU", "PH"]),
    ("Guam-Japan route", ["GU", "JP-SH"]),
    ("Guam-Taiwan route", ["GU", "TW"]),
    ("US-Hawaii-Australia route", ["US-OR", "US-HI", "FJ", "NZ", "AU-SY"]),
    ("East Asia coastal route", ["JP-SH", "KR", "CN-SH", "TW", "HK", "VN", "SG"]),
    ("Hong Kong-Philippines route", ["HK", "PH"]),
    ("Singapore-Indonesia-Australia route", ["SG", "ID", "AU-PE"]),
    ("Southern Australia route", ["AU-PE", "AU-SY"]),
    ("Singapore-India route", ["SG", "IN-CH"]),
    ("India coastal route", ["IN-CH", "LK", "IN-MU"]),
    ("Sri Lanka-Djibouti route", ["LK", "DJ"]),
    ("India-Gulf route", ["IN-MU", "OM", "AE"]),
    ("Pakistan-Oman route", ["PK", "OM"]),
    ("India-Djibouti route", ["IN-MU", "DJ"]),
    ("Red Sea route", ["DJ", "SA", "EG-ZA"]),
    ("Mediterranean route (Egypt-France)", ["EG-AL", "IT", "FR"]),
    ("East Africa route", ["DJ", "KE", "TZ", "MZ", "ZA-DU"]),
    ("India-East Africa route", ["IN-MU", "KE"]),
    ("West Africa route", ["PT", "ES-CN", "SN", "CI", "GH", "NG", "AO", "NA", "ZA-CT"]),
    ("South Africa coastal route", ["ZA-CT", "ZA-DU"]),
    ("South Atlantic route (Angola-Brazil)", ["AO", "BR-FO"]),
    ("South Atlantic route (Portugal-Brazil)", ["PT", "BR-FO"]),
    ("Brazil-Argentina route", ["BR-FO", "BR-RJ", "AR"]),
    ("US-Brazil route", ["US-FL", "BR-FO"]),
    ("Caribbean route", ["US-FL", "PR", "CO", "PA-CAR"]),
    ("Pacific South America route", ["PA-PAC", "PE", "CL"]),
    ("US-Chile route", ["US-LA", "CL"]),
]


# ---------------------------------------------------------------- geometry

def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(wrap_longitude(lon2 - lon1))
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6371.0 * 2 * math.atan2(math.sqrt(a), math.sqrt(max(0.0, 1 - a)))


def wrap_longitude(value: float) -> float:
    while value > 180:
        value -= 360
    while value < -180:
        value += 360
    return value


def unwrap(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Points are (lat, lon); make longitudes continuous across the antimeridian."""
    if not points:
        return points
    result = [points[0]]
    for lat, lon in points[1:]:
        previous = result[-1][1]
        while lon - previous > 180:
            lon -= 360
        while lon - previous < -180:
            lon += 360
        result.append((lat, lon))
    return result


def simplify(points: list[tuple[float, float]], epsilon: float) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        (ay, ax), (by, bx) = points[start], points[end]
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        best, best_index = 0.0, -1
        for index in range(start + 1, end):
            py, px = points[index]
            if length == 0:
                distance = math.hypot(px - ax, py - ay)
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
                distance = math.hypot(px - (ax + t * dx), py - (ay + t * dy))
            if distance > best:
                best, best_index = distance, index
        if best > epsilon and best_index > 0:
            keep[best_index] = True
            stack.append((start, best_index))
            stack.append((best_index, end))
    return [point for point, kept in zip(points, keep) if kept]


def chaikin(points: list[tuple[float, float]], iterations: int) -> list[tuple[float, float]]:
    for _ in range(iterations):
        if len(points) < 3:
            return points
        result = [points[0]]
        for (ay, ax), (by, bx) in zip(points, points[1:]):
            result.append((0.75 * ay + 0.25 * by, 0.75 * ax + 0.25 * bx))
            result.append((0.25 * ay + 0.75 * by, 0.25 * ax + 0.75 * bx))
        result.append(points[-1])
        points = result
    return points


def path_km(points: list[tuple[float, float]]) -> float:
    return sum(haversine_km(a[0], a[1], b[0], b[1]) for a, b in zip(points, points[1:]))


def rounded(points: list[tuple[float, float]]) -> list[list[float]]:
    return [[round(lat, 3), round(wrap_longitude(lon), 3)] for lat, lon in points]


# ---------------------------------------------------------- natural earth

def read_dbf(data: bytes) -> list[dict[str, str]]:
    record_count, header_length, record_length = struct.unpack_from("<IHH", data, 4)
    fields = []
    offset = 32
    while data[offset] != 0x0D:
        name = data[offset:offset + 11].split(b"\0", 1)[0].decode("ascii")
        length = data[offset + 16]
        fields.append((name, length))
        offset += 32
    records = []
    for index in range(record_count):
        start = header_length + index * record_length + 1
        record = {}
        for name, length in fields:
            raw = data[start:start + length].split(b"\0", 1)[0]
            record[name] = raw.decode("utf-8", "replace").strip()
            start += length
        records.append(record)
    return records


def read_shapes(data: bytes) -> list[list[list[tuple[float, float]]]]:
    shapes = []
    offset = 100
    while offset + 8 <= len(data):
        _, words = struct.unpack_from(">ii", data, offset)
        content = data[offset + 8:offset + 8 + words * 2]
        offset += 8 + words * 2
        rings: list[list[tuple[float, float]]] = []
        if len(content) >= 44 and struct.unpack_from("<i", content, 0)[0] in (5, 15, 25):
            parts, count = struct.unpack_from("<ii", content, 36)
            starts = list(struct.unpack_from(f"<{parts}i", content, 44)) + [count]
            base = 44 + parts * 4
            for start, end in zip(starts, starts[1:]):
                ring = [struct.unpack_from("<dd", content, base + i * 16) for i in range(start, end)]
                rings.append([(lat, lon) for lon, lat in ring])
        shapes.append(rings)
    return shapes


def read_countries(source: Path) -> tuple[list[str], dict[str, list[float]], list[list[list[tuple[float, float]]]], str]:
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        dbf = archive.read(next(n for n in names if n.endswith(".dbf")))
        shp = archive.read(next(n for n in names if n.endswith(".shp")))
        version = archive.read(next(n for n in names if n.endswith("VERSION.txt"))).decode().strip()
    records = read_dbf(dbf)
    shapes = read_shapes(shp)
    codes, labels, areas = [], {}, {}
    for record, rings in zip(records, shapes):
        code = record.get("ISO_A2_EH") or record.get("ISO_A2") or ""
        if len(code) != 2 or not code.isalpha():
            code = ""
        code = code.upper()
        codes.append(code)
        if not code:
            continue
        # Several records can share a code (a country and its small territories);
        # label the country with its largest record.
        area = sum(abs(ring_area(ring)) for ring in rings)
        if area > areas.get(code, -1.0):
            areas[code] = area
            labels[code] = [round(float(record["LABEL_Y"]), 3), round(float(record["LABEL_X"]), 3)]
    return codes, labels, shapes, version


def ring_area(ring: list[tuple[float, float]]) -> float:
    return 0.5 * sum(a[1] * b[0] - b[1] * a[0] for a, b in zip(ring, ring[1:] + ring[:1]))


def rasterize(codes: list[str], shapes: list, code_index: dict[str, int]) -> bytearray:
    grid = bytearray(GRID_WIDTH * GRID_HEIGHT)
    for code, rings in zip(codes, shapes):
        if not code:
            continue
        value = code_index[code]
        edges = []
        for ring in rings:
            for (lat1, lon1), (lat2, lon2) in zip(ring, ring[1:] + ring[:1]):
                if lat1 != lat2:
                    edges.append((lat1, lon1, lat2, lon2))
        if not edges:
            continue
        top = max(max(e[0], e[2]) for e in edges)
        bottom = min(min(e[0], e[2]) for e in edges)
        first_row = max(0, int((90 - top) / GRID_STEP))
        last_row = min(GRID_HEIGHT - 1, int((90 - bottom) / GRID_STEP))
        for row in range(first_row, last_row + 1):
            lat = 90 - (row + 0.5) * GRID_STEP
            crossings = []
            for lat1, lon1, lat2, lon2 in edges:
                if (lat1 <= lat < lat2) or (lat2 <= lat < lat1):
                    crossings.append(lon1 + (lat - lat1) * (lon2 - lon1) / (lat2 - lat1))
            crossings.sort()
            for west, east in zip(crossings[0::2], crossings[1::2]):
                start = max(0, math.ceil((west + 180) / GRID_STEP - 0.5))
                end = min(GRID_WIDTH - 1, math.floor((east + 180) / GRID_STEP - 0.5))
                for column in range(start, end + 1):
                    grid[row * GRID_WIDTH + column] = value
    return grid


def cell(lat: float, lon: float) -> tuple[int, int]:
    row = min(GRID_HEIGHT - 1, max(0, int((90 - lat) / GRID_STEP)))
    column = int((wrap_longitude(lon) + 180) / GRID_STEP) % GRID_WIDTH
    return row, column


def cell_center(row: int, column: int) -> tuple[float, float]:
    return 90 - (row + 0.5) * GRID_STEP, -180 + (column + 0.5) * GRID_STEP


def nearest_land(grid: bytearray, lat: float, lon: float, radius: int) -> int:
    row, column = cell(lat, lon)
    best, best_distance = 0, math.inf
    for dr in range(-radius, radius + 1):
        r = row + dr
        if not 0 <= r < GRID_HEIGHT:
            continue
        for dc in range(-radius, radius + 1):
            value = grid[r * GRID_WIDTH + (column + dc) % GRID_WIDTH]
            if value and dr * dr + dc * dc < best_distance:
                best, best_distance = value, dr * dr + dc * dc
    return best


def land_share(grid: bytearray, a: tuple[float, float], b: tuple[float, float]) -> float:
    km = haversine_km(a[0], a[1], b[0], b[1])
    samples = max(2, int(km / 20))
    (lat1, lon1), (lat2, lon2) = unwrap([a, b])
    land = 0
    for index in range(samples + 1):
        t = index / samples
        row, column = cell(lat1 + (lat2 - lat1) * t, lon1 + (lon2 - lon1) * t)
        land += 1 if grid[row * GRID_WIDTH + column] else 0
    return land / (samples + 1)


# ------------------------------------------------------------ sea routing

def sea_route(grid: bytearray, start: tuple[float, float], end: tuple[float, float]) -> list[tuple[float, float]]:
    start_cell, end_cell = cell(*start), cell(*end)
    end_lat, end_lon = cell_center(*end_cell)

    def cost_of(row: int, column: int) -> float:
        index = row * GRID_WIDTH + column
        if grid[index]:
            return 25.0
        for dr, dc in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            r = row + dr
            if 0 <= r < GRID_HEIGHT and grid[r * GRID_WIDTH + (column + dc) % GRID_WIDTH]:
                return 1.3
        return 1.0

    def heuristic(row: int, column: int) -> float:
        lat, lon = cell_center(row, column)
        return haversine_km(lat, lon, end_lat, end_lon)

    frontier = [(heuristic(*start_cell), 0.0, start_cell)]
    best = {start_cell: 0.0}
    previous: dict[tuple[int, int], tuple[int, int]] = {}
    while frontier:
        _, spent, current = heapq.heappop(frontier)
        if current == end_cell:
            break
        if spent > best.get(current, math.inf):
            continue
        row, column = current
        lat, lon = cell_center(row, column)
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                if dr == 0 and dc == 0:
                    continue
                r, c = row + dr, (column + dc) % GRID_WIDTH
                if not 0 <= r < GRID_HEIGHT:
                    continue
                nlat, nlon = cell_center(r, c)
                step = haversine_km(lat, lon, nlat, nlon) * cost_of(r, c)
                total = spent + step
                if total < best.get((r, c), math.inf):
                    best[(r, c)] = total
                    previous[(r, c)] = current
                    heapq.heappush(frontier, (total + heuristic(r, c), total, (r, c)))
    if end_cell not in best:
        raise ValueError(f"no sea route between {start} and {end}")
    cells = [end_cell]
    while cells[-1] != start_cell:
        cells.append(previous[cells[-1]])
    cells.reverse()
    points = unwrap([start] + [cell_center(*c) for c in cells[1:-1]] + [end])
    points = simplify(points, ROUTE_SIMPLIFY_DEGREES)
    return chaikin(points, 2)


# ------------------------------------------------------------- build data

def build_ip_table(ipv4: Path, ipv6: Path) -> tuple[bytes, list[str]]:
    def load(path: Path, bits: int) -> list[tuple[int, int, str]]:
        rows = []
        with path.open(newline="") as handle:
            for start, end, code in csv.reader(handle):
                rows.append((int(ipaddress.ip_address(start)), int(ipaddress.ip_address(end)), code.upper()))
        rows.sort()
        entries = []
        cursor = 0
        for start, end, code in rows:
            if start > cursor:
                entries.append((cursor, ""))
            entries.append((start, code))
            cursor = end + 1
        if cursor < 1 << bits:
            entries.append((cursor, ""))
        merged = []
        for start, code in entries:
            if merged and merged[-1][1] == code:
                continue
            merged.append((start, code))
        return merged

    v4 = load(ipv4, 32)
    v6_full = load(ipv6, 128)
    v6 = []
    for start, code in v6_full:
        prefix = start >> 64
        if v6 and v6[-1][0] == prefix:
            continue
        if v6 and v6[-1][1] == code:
            continue
        v6.append((prefix, code))
    codes = sorted({code for _, code in v4 + v6 if code})
    if len(codes) > 254:
        raise ValueError("too many country codes for one-byte indexes")
    index = {code: i + 1 for i, code in enumerate(codes)}
    index[""] = 0

    def varints(values: list[int]) -> bytes:
        out = bytearray()
        previous = 0
        for value in values:
            delta = value - previous
            previous = value
            while True:
                byte = delta & 0x7F
                delta >>= 7
                out.append(byte | (0x80 if delta else 0))
                if not delta:
                    break
        return bytes(out)

    body = bytearray(b"RIFTIPC1")
    body += struct.pack("<IIB", len(v4), len(v6), len(codes))
    body += "".join(codes).encode("ascii")
    body += varints([start for start, _ in v4])
    body += bytes(index[code] for _, code in v4)
    body += varints([start for start, _ in v6])
    body += bytes(index[code] for _, code in v6)
    return deflate(bytes(body)), codes


def build_grid_file(grid: bytearray, codes: list[str]) -> bytes:
    body = bytearray(b"RIFTCG01")
    body += struct.pack("<HHB", GRID_WIDTH, GRID_HEIGHT, len(codes))
    body += "".join(codes).encode("ascii")
    for row in range(GRID_HEIGHT):
        runs = []
        values = grid[row * GRID_WIDTH:(row + 1) * GRID_WIDTH]
        start = 0
        for column in range(1, GRID_WIDTH + 1):
            if column == GRID_WIDTH or values[column] != values[start]:
                runs.append((column - start, values[start]))
                start = column
        body += struct.pack("<H", len(runs))
        for length, value in runs:
            body += struct.pack("<HB", length, value)
    return deflate(bytes(body))


def deflate(data: bytes) -> bytes:
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


def canonical_sha256(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def read_osm_segments(source: Path, expected_sha256: str) -> list[tuple[str, list[tuple[float, float]]]]:
    payload = json.loads(source.read_text(encoding="utf-8"))
    elements = payload.get("elements", [])
    actual = canonical_sha256(elements)
    if actual != expected_sha256:
        raise ValueError(f"OpenStreetMap element checksum mismatch: expected {expected_sha256}, got {actual}")
    segments = []
    for element in sorted(elements, key=lambda e: e.get("id", 0)):
        if element.get("type") != "way":
            continue
        tags = element.get("tags", {})
        if tags.get("location") in ("underground", "overground"):
            continue
        geometry = element.get("geometry") or []
        points = unwrap([(float(p["lat"]), float(p["lon"])) for p in geometry])
        if len(points) < 2 or path_km(points) < MIN_SEGMENT_KM:
            continue
        name = (tags.get("name") or tags.get("ref") or "").strip() or "Undersea cable"
        segments.append((name, simplify(points, OSM_SIMPLIFY_DEGREES)))
    return segments


class NodeIndex:
    def __init__(self) -> None:
        self.nodes: list[dict] = []
        self.buckets: dict[tuple[int, int], list[int]] = {}

    def find_or_add(self, lat: float, lon: float, country: str | None = None, name: str | None = None) -> int:
        lon = wrap_longitude(lon)
        key = (int(lat // 0.5), int(lon // 0.5))
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                for index in self.buckets.get((key[0] + dr, key[1] + dc), []):
                    node = self.nodes[index]
                    if haversine_km(lat, lon, node["lat"], node["lon"]) <= NODE_MERGE_KM:
                        if country and not node.get("country"):
                            node["country"] = country
                        if name and not node.get("name"):
                            node["name"] = name
                        return index
        self.nodes.append({"lat": lat, "lon": lon, "country": country, "name": name})
        self.buckets.setdefault(key, []).append(len(self.nodes) - 1)
        return len(self.nodes) - 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--countries-zip", required=True, type=Path)
    parser.add_argument("--ipv4-csv", required=True, type=Path)
    parser.add_argument("--ipv6-csv", required=True, type=Path)
    parser.add_argument("--osm-json", required=True, type=Path)
    parser.add_argument("--osm-elements-sha256", required=True)
    parser.add_argument("--source-label", required=True)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    ip_table, ip_codes = build_ip_table(arguments.ipv4_csv, arguments.ipv6_csv)
    country_codes, labels, shapes, ne_version = read_countries(arguments.countries_zip)
    grid_codes = sorted({code for code in country_codes if code})
    code_index = {code: i + 1 for i, code in enumerate(grid_codes)}
    grid = rasterize(country_codes, shapes, code_index)

    def grid_country(lat: float, lon: float) -> str | None:
        value = nearest_land(grid, lat, lon, LANDING_SEARCH_CELLS)
        return grid_codes[value - 1] if value else None

    nodes = NodeIndex()
    cables: list[dict] = []
    segments: list[list] = []
    cable_ids: dict[tuple[str, bool], int] = {}

    def cable_id(name: str, approximate: bool) -> int:
        key = (name, approximate)
        if key not in cable_ids:
            cable_ids[key] = len(cables)
            cables.append({"name": name, "approximate": approximate})
        return cable_ids[key]

    for key, (name, lat, lon, country) in HUBS.items():
        nodes.find_or_add(lat, lon, country, name)

    for name, points in read_osm_segments(arguments.osm_json, arguments.osm_elements_sha256):
        start = nodes.find_or_add(points[0][0], points[0][1])
        end = nodes.find_or_add(points[-1][0], points[-1][1])
        if start == end:
            continue
        segments.append([cable_id(name, False), start, end, round(path_km(points), 1), rounded(points)])

    for name, stops in ROUTES:
        for a, b in zip(stops, stops[1:]):
            hub_a, hub_b = HUBS[a], HUBS[b]
            points = sea_route(grid, (hub_a[1], hub_a[2]), (hub_b[1], hub_b[2]))
            start = nodes.find_or_add(hub_a[1], hub_a[2], hub_a[3], hub_a[0])
            end = nodes.find_or_add(hub_b[1], hub_b[2], hub_b[3], hub_b[0])
            segments.append([cable_id(name, True), start, end, round(path_km(points), 1), rounded(points)])

    for node in nodes.nodes:
        if not node.get("country"):
            node["country"] = grid_country(node["lat"], node["lon"])

    landings = [i for i, node in enumerate(nodes.nodes) if node.get("country")]
    land_links = []
    for position, a in enumerate(landings):
        node_a = nodes.nodes[a]
        for b in landings[position + 1:]:
            node_b = nodes.nodes[b]
            km = haversine_km(node_a["lat"], node_a["lon"], node_b["lat"], node_b["lon"])
            if km > LAND_LINK_MAX_KM:
                continue
            same_country = node_a["country"] == node_b["country"]
            if (same_country and km <= SAME_COUNTRY_LINK_MAX_KM) or land_share(
                grid, (node_a["lat"], node_a["lon"]), (node_b["lat"], node_b["lon"])
            ) >= LAND_LINK_MIN_LAND_SHARE:
                land_links.append([a, b, round(km, 1)])

    arguments.output.mkdir(parents=True, exist_ok=True)
    (arguments.output / "ip-country.bin").write_bytes(ip_table)
    (arguments.output / "country-grid.bin").write_bytes(build_grid_file(grid, grid_codes))

    network = {
        "format": 1,
        "source": arguments.source_label,
        "countries": dict(sorted(labels.items())),
        "cables": cables,
        "nodes": [[round(n["lat"], 3), round(n["lon"], 3), n.get("country") or ""] for n in nodes.nodes],
        "segments": segments,
        "landLinks": land_links,
    }
    lines = ["{"]
    for key in ("format", "source", "countries"):
        lines.append(f'  "{key}": {json.dumps(network[key], ensure_ascii=False, separators=(",", ":"))},')
    for key in ("cables", "nodes", "segments", "landLinks"):
        items = ",\n    ".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) for item in network[key])
        suffix = "," if key != "landLinks" else ""
        lines.append(f'  "{key}": [\n    {items}\n  ]{suffix}')
    lines.append("}")
    (arguments.output / "network-map.json").write_text("\n".join(lines) + "\n", encoding="utf-8")

    approximate = sum(1 for c in cables if c["approximate"])
    print(f"Natural Earth {ne_version}; {len(ip_codes)} IP country codes; {len(cables)} cables "
          f"({approximate} approximate routes); {len(nodes.nodes)} nodes; {len(segments)} segments; "
          f"{len(land_links)} land links")


if __name__ == "__main__":
    main()
