#!/usr/bin/env bash
# 使い方:
#   scripts/build_map.sh <地域データ> <中心緯度> <中心経度>
# 例:
#   scripts/build_map.sh maps/chubu-260816-free.gpkg/chubu.gpkg 34.97 136.87
#   scripts/build_map.sh ~/Downloads/kanto-latest.osm.pbf 35.6812 139.7671
#
# 地域全体の OSM 抽出データから、中心の周囲 map_radius_m だけを切り出し、
# 端末に置く形式(WalkMap の JSON)へ変換する。
#
# 入力は 2 形式に対応する:
#   .gpkg      Geofabrik の GeoPackage。SQLite なので osmium を通さず直接読む
#   .osm.pbf   osmium で矩形に切り出してから変換する
#
# なぜこの手順か(docs/04「OSM データの持ち方」):
# - 地域単位の pbf は公開配布物なので、落としても自宅は漏れない。切り出しは手元で行う
# - 生成物はリポジトリに入れない(maps/ は gitignore)。公開履歴に自宅周辺を残さない
# - アプリに通信コードを入れない
#
# 事前準備:
#   .osm.pbf を使う場合のみ: brew install osmium-tool
#   地域データを入手(例: Geofabrik の日本 > 中部)。数百 MB〜数 GB
#
# 生成物を iPhone へ入れる:
#   Finder > iPhone > ファイル > OtoSanpo に maps/otosanpo-map.json をドラッグ
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 3 ]; then
  echo "使い方: scripts/build_map.sh <地域データ(.gpkg か .osm.pbf)> <中心緯度> <中心経度>" >&2
  exit 1
fi

PBF="$1"
LAT="$2"
LON="$3"

if [ ! -f "$PBF" ]; then
  echo "地域データが見つかりません: $PBF" >&2
  echo "Geofabrik などから .gpkg か .osm.pbf を入手してください。" >&2
  exit 1
fi

RADIUS=$(scripts/read_param.sh route.map_radius_m)
OUT_DIR=maps
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR" logs

BIN=build-mapbuild/Build/Products/Debug/otosanpo-mapbuild
build_tool() {
  if ! xcodebuild -project OtoSanpo.xcodeproj -scheme MapBuild \
      -destination 'platform=macOS' -derivedDataPath build-mapbuild build \
      >> logs/build_map.log 2>&1; then
    tail -n 40 logs/build_map.log
    echo "変換ツールのビルドに失敗しました" >&2
    exit 1
  fi
}

case "$PBF" in
  *.gpkg)
    echo "1/2 変換ツールを用意"
    : > logs/build_map.log
    build_tool
    echo "2/2 GeoPackage から $RADIUS m 圏を切り出して変換"
    "$BIN" "$PBF" "$OUT_DIR/otosanpo-map.json" "$LAT" "$LON" "$RADIUS" "$(date +%Y-%m-%d)"
    echo
    echo "Finder > iPhone > ファイル > OtoSanpo に $OUT_DIR/otosanpo-map.json をドラッグしてください。"
    exit 0
    ;;
esac

if ! command -v osmium > /dev/null; then
  echo "osmium が見つかりません(.osm.pbf の処理に必要)。次で入れてください:" >&2
  echo "  brew install osmium-tool" >&2
  exit 1
fi

# 円を覆う矩形を出す。osmium は矩形でしか切れないので、円の外は変換側で落とす
BBOX=$(awk -v lat="$LAT" -v lon="$LON" -v r="$RADIUS" 'BEGIN {
  dlat = r / 111320.0;
  dlon = r / (111320.0 * cos(lat * 3.14159265358979 / 180.0));
  printf "%.6f,%.6f,%.6f,%.6f", lon - dlon, lat - dlat, lon + dlon, lat + dlat;
}')

echo "1/4 矩形で切り出し($BBOX)"
osmium extract --bbox "$BBOX" --set-bounds -o "$WORK/area.osm.pbf" "$PBF" \
  > logs/build_map.log 2>&1

echo "2/4 歩ける道のタグだけ残す"
osmium tags-filter -o "$WORK/ways.osm.pbf" "$WORK/area.osm.pbf" \
  w/highway=footway,path,pedestrian,steps,track,cycleway,residential,living_street,service,unclassified,road,primary,secondary,tertiary,primary_link,secondary_link,tertiary_link \
  >> logs/build_map.log 2>&1

echo "3/4 GeoJSON へ書き出し"
osmium export -f geojsonseq --geometry-types=linestring \
  -o "$WORK/ways.geojsonseq" "$WORK/ways.osm.pbf" >> logs/build_map.log 2>&1

echo "4/4 端末に置く形式へ変換"
build_tool

"$BIN" "$WORK/ways.geojsonseq" "$OUT_DIR/otosanpo-map.json" \
  "$LAT" "$LON" "$RADIUS" "$(date +%Y-%m-%d)"

echo
echo "Finder > iPhone > ファイル > OtoSanpo に $OUT_DIR/otosanpo-map.json をドラッグしてください。"
