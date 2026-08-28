#!/usr/bin/env python3
"""`maps/set/` から配信用の一覧(index.json)を作る。

使い方:
    scripts/build_map_catalog.py

出力: maps/set/index.json

**アップロードはしない。** 外向きの操作と認証情報が要るので人が行う
(実機への配備を手で行うのと同じ方針)。上げ方は docs/12。

一覧に入れるのは、アプリが「どれを落とすか」を選ぶのに要る情報だけ:
名前・ファイル名・バイト数・中心・半径・生成日。**利用者の情報は一切入らない。**
"""
import json
import pathlib
import sys

SET_DIR = pathlib.Path(__file__).resolve().parent.parent / "maps" / "set"


def main() -> int:
    if not SET_DIR.is_dir():
        print(f"{SET_DIR} がありません。scripts/build_maps.sh で作ってください", file=sys.stderr)
        return 1

    cities = []
    for path in sorted(SET_DIR.glob("*.json")):
        if path.name == "index.json":
            continue
        try:
            with path.open(encoding="utf-8") as f:
                m = json.load(f)
        except Exception as e:  # 壊れたファイルは一覧に載せない
            print(f"読めないので飛ばします: {path.name}({e})", file=sys.stderr)
            continue
        missing = [k for k in ("center", "radius_m", "generated") if k not in m]
        if missing:
            print(f"鍵が足りないので飛ばします: {path.name}({missing})", file=sys.stderr)
            continue
        cities.append({
            "name": path.stem,
            "file": path.name,
            "bytes": path.stat().st_size,
            "radius_m": m["radius_m"],
            "center": m["center"],
            "generated": m["generated"],
        })

    if not cities:
        print("載せられる地図がありません", file=sys.stderr)
        return 1

    # 大きい順に並べる = だいたい人口順。位置が取れない端末ではこの順に出る
    cities.sort(key=lambda c: -c["bytes"])

    newest = max(c["generated"] for c in cities)
    out = SET_DIR / "index.json"
    with out.open("w", encoding="utf-8") as f:
        json.dump({"generated": newest, "cities": cities}, f,
                  ensure_ascii=False, indent=2)
        f.write("\n")

    total = sum(c["bytes"] for c in cities)
    print(f"{out}: {len(cities)} 都市 / 合計 {total / 1e6:.0f} MB")
    for c in cities[:5]:
        print(f"  {c['name']}\t{c['bytes'] / 1e6:.1f} MB\t半径 {c['radius_m'] / 1000:.0f}km")
    print("  …")
    print()
    print("配信先へ上げる(人が行う。認証情報が要るため):")
    print("  npx wrangler r2 object put <バケット>/index.json --file maps/set/index.json")
    print("  ※ 各都市の .json も同じ場所へ上げること。詳細は docs/12")
    return 0


if __name__ == "__main__":
    sys.exit(main())
