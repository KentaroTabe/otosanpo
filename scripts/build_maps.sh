#!/usr/bin/env bash
# 使い方:
#   scripts/build_maps.sh <地域データ.gpkg> <一覧.tsv>
#
# 一覧の 1 行 = 1 ファイル。タブ区切りで:
#   名前  中心緯度  中心経度  半径m
#
# 出力は maps/set/<名前>.json。テスターごとに 1 つ作るのではなく、
# **同じ都市圏の人には同じファイルを渡す**ための道具。
# 住所を聞かなくても「どの市の近くか」だけで足りるようになる。
#
# 一覧は都道府県から作れる:
#   scripts/pref_bbox.py --build-list 20000 maps/chubu-260816-free.gpkg/chubu.gpkg > 一覧.tsv
#
# **半径は 20 km 程度までにすること。** それを超えるとアプリが読み込めない。
# 実測(2026-08-28・Mac の Debug ビルド):
#
#   半径  サイズ   節点      経路の場の構築  最大メモリ
#    5km  2.1MB    57,486    0.46秒          38MB
#   20km   23MB   577,315    5.1秒          241MB
#   60km  112MB 2,797,111   40.7秒          615MB
#
# 経路の場は**散歩を開始した瞬間に**作る。60 km ではそこで数秒〜十秒固まり、
# メモリも危ない。詳細は docs/04「OSM データの持ち方」。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 2 ]; then
  echo "使い方: scripts/build_maps.sh <地域データ.gpkg> <一覧.tsv>" >&2
  exit 1
fi

SRC="$1"
LIST="$2"

if [ ! -f "$SRC" ]; then
  echo "地域データが見つかりません: $SRC" >&2
  exit 1
fi
if [ ! -f "$LIST" ]; then
  echo "一覧が見つかりません: $LIST" >&2
  exit 1
fi

OUT_DIR=maps/set
mkdir -p "$OUT_DIR" logs
BIN=build-mapbuild/Build/Products/Debug/otosanpo-mapbuild

if [ ! -x "$BIN" ]; then
  echo "変換ツールを用意"
  if ! xcodebuild -project OtoSanpo.xcodeproj -scheme MapBuild \
      -destination 'platform=macOS' -derivedDataPath build-mapbuild build \
      > logs/build_maps.log 2>&1; then
    tail -n 40 logs/build_maps.log
    echo "変換ツールのビルドに失敗しました" >&2
    exit 1
  fi
fi

TODAY=$(date +%Y-%m-%d)

# 1 件ごとに 40 秒ほどかかる(地域データを毎回走査するため)
while IFS=$'\t' read -r NAME LAT LON RADIUS; do
  case "$NAME" in ""|\#*) continue ;; esac
  echo "--- $NAME(半径 $((RADIUS / 1000)) km)---"
  "$BIN" "$SRC" "$OUT_DIR/${NAME}.json" "$LAT" "$LON" "$RADIUS" "$TODAY"
done < "$LIST"

echo
echo "できたもの:"
ls -lh "$OUT_DIR"
echo
echo "テスターには、その人の都市圏のファイルを 1 つ渡してください。"
echo "端末での置き場所は手順書のとおり(iPhone: ファイル > OtoSanpo)。"
