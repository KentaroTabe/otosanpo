#!/usr/bin/env python3
"""地図を作る対象(中心と半径)を、地域データから出す。

使い方:
    scripts/map_targets.py <地域データ.gpkg>                    都市を人口順に出す
    scripts/map_targets.py --prefectures <地域データ.gpkg>      都道府県の範囲を出す
    scripts/map_targets.py --build-list <地域データ.gpkg>       build_maps.sh 用の 4 列

    --min-population N   これ未満の都市を落とす(既定 100000)
    --radius M           出力する半径 [m](既定 20000)
    --limit N            上位 N 件だけ

なぜ座標を手で書かないか:
    都市や県の位置を記憶から書くと、確かめようがない誤りが混ざる。
    地域データには都市の点(人口つき)と admin_level4(都道府県)の多角形が
    入っているので、そこから測る。

**半径は 20 km 程度までにすること。** 実測(2026-08-28・Mac の Debug ビルド):

    半径  サイズ   節点      経路の場の構築  最大メモリ
     5km  2.1MB    57,486    0.46秒          38MB
    20km   23MB   577,315    5.1秒          241MB
    60km  112MB 2,797,111   40.7秒          615MB

経路の場は**散歩を開始した瞬間に**作るので、大きすぎるとそこで固まる。
都道府県まるごと(外接半径 60〜160 km)は入らない。→ docs/04
"""
import math
import sqlite3
import struct
import sys

# GeoPackage のジオメトリは独自ヘッダ + 標準 WKB。
# ヘッダ: 'GP'(2) + version(1) + flags(1) + srs_id(4) + envelope(可変)
ENVELOPE_SIZE = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}


def wkb_offset(blob: bytes) -> int:
    """WKB 本体が始まる位置。"""
    if blob[:2] != b"GP":
        raise ValueError("GeoPackage のジオメトリではありません")
    indicator = (blob[3] >> 1) & 0x07
    if indicator not in ENVELOPE_SIZE:
        raise ValueError(f"未知の envelope 指定: {indicator}")
    return 8 + ENVELOPE_SIZE[indicator]


class Reader:
    def __init__(self, blob: bytes):
        self.blob = blob
        self.pos = wkb_offset(blob)

    def take(self, fmt: str):
        size = struct.calcsize(fmt)
        value = struct.unpack_from(fmt, self.blob, self.pos)
        self.pos += size
        return value

    def endian(self) -> str:
        (order,) = self.take("B")
        return "<" if order == 1 else ">"


def read_point(blob: bytes):
    r = Reader(blob)
    e = r.endian()
    (geom_type,) = r.take(e + "I")
    if geom_type % 1000 != 1:
        raise ValueError(f"点ではありません: {geom_type}")
    lon, lat = r.take(e + "2d")
    return lat, lon


def read_polygons(blob: bytes):
    """(頂点数, 最小経度, 最小緯度, 最大経度, 最大緯度) を多角形ごとに返す。"""
    r = Reader(blob)

    def one_polygon(e: str):
        """外環だけ見る。内環(穴)は範囲に影響しない。"""
        (rings,) = r.take(e + "I")
        bounds = None
        count = 0
        for ring in range(rings):
            (points,) = r.take(e + "I")
            coords = r.take(e + f"{points * 2}d")
            if ring == 0:
                lons, lats = coords[0::2], coords[1::2]
                bounds = (min(lons), min(lats), max(lons), max(lats))
                count = points
        return count, bounds

    e = r.endian()
    (geom_type,) = r.take(e + "I")
    base = geom_type % 1000

    out = []
    if base == 3:  # Polygon
        count, bounds = one_polygon(e)
        if bounds:
            out.append((count,) + bounds)
    elif base == 6:  # MultiPolygon
        (n,) = r.take(e + "I")
        for _ in range(n):
            sub = r.endian()
            r.take(sub + "I")  # 型は Polygon 固定
            count, bounds = one_polygon(sub)
            if bounds:
                out.append((count,) + bounds)
    else:
        raise ValueError(f"多角形ではありません: {geom_type}")
    return out


def prefectures(conn, radius_m: float, build_list: bool, limit):
    rows = conn.execute(
        "SELECT name, geom FROM gis_osm_adminareas_a_free"
        " WHERE fclass = 'admin_level4' AND name IS NOT NULL ORDER BY name"
    ).fetchall()
    shown = 0
    for name, blob in rows:
        polygons = read_polygons(blob)
        if not polygons:
            continue
        # **頂点数が最大のもの = 本土側。**
        # 東京都の小笠原や鹿児島県の奄美を含めると外接円が数百 km になり、使えない
        _, min_lon, min_lat, max_lon, max_lat = max(polygons, key=lambda p: p[0])
        mid_lat, mid_lon = (min_lat + max_lat) / 2, (min_lon + max_lon) / 2
        height_m = (max_lat - min_lat) * 111320
        width_m = (max_lon - min_lon) * 111320 * math.cos(math.radians(mid_lat))
        enclosing_m = math.hypot(width_m, height_m) / 2

        if build_list:
            # **矩形の中心は人の住む所とは限らない**(愛知県の中心は名古屋から外れる)。
            # 都道府県を単位にするより、都市を単位にしたほうが当たる
            print(f"{name}\t{mid_lat:.5f}\t{mid_lon:.5f}\t{radius_m:.0f}")
        else:
            print(f"{name}\t中心 {mid_lat:.4f},{mid_lon:.4f}"
                  f"\t外接半径 {enclosing_m / 1000:.0f}km"
                  f"\t矩形 {width_m * height_m / 1e6:.0f}km2")
        shown += 1
        if limit and shown >= limit:
            break


def cities(conn, radius_m: float, build_list: bool, min_population: int, limit):
    rows = conn.execute(
        "SELECT name, population, geom FROM gis_osm_places_free"
        " WHERE fclass IN ('city', 'town') AND name IS NOT NULL"
        " AND population >= ? ORDER BY population DESC",
        (min_population,),
    ).fetchall()
    shown = 0
    for name, population, blob in rows:
        lat, lon = read_point(blob)
        if build_list:
            print(f"{name}\t{lat:.5f}\t{lon:.5f}\t{radius_m:.0f}")
        else:
            print(f"{name}\t人口 {population}\t{lat:.4f},{lon:.4f}")
        shown += 1
        if limit and shown >= limit:
            break


def main() -> int:
    argv = sys.argv[1:]
    mode = "cities"
    build_list = False
    radius_m = 20000.0
    min_population = 100000
    limit = None
    path = None

    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--prefectures":
            mode = "prefectures"
        elif a == "--cities":
            mode = "cities"
        elif a == "--build-list":
            build_list = True
        elif a == "--radius":
            i += 1
            radius_m = float(argv[i])
        elif a == "--min-population":
            i += 1
            min_population = int(argv[i])
        elif a == "--limit":
            i += 1
            limit = int(argv[i])
        elif a.startswith("--"):
            print(f"知らない指定: {a}", file=sys.stderr)
            return 1
        else:
            path = a
        i += 1

    if path is None:
        print(__doc__, file=sys.stderr)
        return 1

    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    if mode == "prefectures":
        prefectures(conn, radius_m, build_list, limit)
    else:
        cities(conn, radius_m, build_list, min_population, limit)
    return 0


if __name__ == "__main__":
    sys.exit(main())
