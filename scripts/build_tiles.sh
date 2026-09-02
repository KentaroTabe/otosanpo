#!/usr/bin/env bash
# 使い方:
#   scripts/build_tiles.sh                     maps/ にある全地方からタイルを作る
#   scripts/build_tiles.sh <地域データ.gpkg>    1 地方だけ作る(検証用)
#
# 配信用のタイル(緯度経度の等分割・1 枚 = 1 つの WalkMap)を maps/tiles/ に作る。
# タイル角は config/parameters.json の map_download.tile_size_deg(スクリプトに数値を書かない)。
#
# **アップロードはしない。** 外向きの操作と認証情報が要るので人が行う
# (scripts/upload_tiles.sh を人が実行する。→ docs/12)。
#
# 地方データは境界で重なるため、既にあるタイルへは重複を除いて追記される。
# **作り直すときは maps/tiles/ を消してから**(古い日付のタイルが混ざるのを避ける)。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p logs maps/tiles
LOG=logs/build_tiles.log
BIN=build-mapbuild/Build/Products/Debug/otosanpo-mapbuild

# **毎回ビルドする**(増分なので数秒)。古いバイナリが残っていると
# 新しい引数を知らないまま動いて紛らわしい(2026-08-28 に踏んだ)
echo "変換ツールを用意"
if ! xcodebuild -project OtoSanpo.xcodeproj -scheme MapBuild \
    -destination 'platform=macOS' -derivedDataPath build-mapbuild build > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "変換ツールのビルドに失敗しました" >&2
  exit 1
fi

SIZE_DEG=$(scripts/read_param.sh map_download.tile_size_deg)
TODAY=$(date +%Y-%m-%d)

if [ $# -ge 1 ]; then
  SOURCES=("$1")
else
  # maps/ 直下の地方ディレクトリ(<地方>-<日付>-free.gpkg/<地方>.gpkg)を全部
  SOURCES=()
  for d in maps/*-free.gpkg; do
    [ -d "$d" ] || continue
    for g in "$d"/*.gpkg; do
      [ -f "$g" ] && SOURCES+=("$g")
    done
  done
fi

if [ ${#SOURCES[@]} -eq 0 ]; then
  echo "地域データ(.gpkg)が見つかりません。maps/ に置いてください" >&2
  exit 1
fi

for SRC in "${SOURCES[@]}"; do
  echo "================ $SRC ================"
  "$BIN" --tiles "$SRC" maps/tiles "$SIZE_DEG" "$TODAY"
done

echo
COUNT=$(ls maps/tiles | grep -c '^t' || true)
echo "できたもの: maps/tiles/ にタイル $COUNT 枚"
du -sh maps/tiles
echo
echo "配信先へ上げる(人が実行する): scripts/upload_tiles.sh <バケット名>"
