#!/usr/bin/env bash
# 使い方: scripts/walk_check.sh <ログ> [開始時刻の接頭辞]
#   例: scripts/walk_check.sh field-logs/xxx.tsv 2026-10-31
#
# 散歩のあとに、確かめたい項目(docs/05「次の散歩で確かめること」)を 1 度に見る。
# 2026-10-31 以降のログが対象。読むだけで何も書き換えない。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
FROM="${2:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "使い方: scripts/walk_check.sh <ログ> [開始時刻の接頭辞]" >&2
  exit 1
fi

lines() {
  awk -F '\t' -v FROM="$FROM" -v PAT="$1" \
    'FROM != "" && $1 < FROM { next } $5 ~ PAT { print substr($1, 12, 8) "  " $2 "  " $5 }' "$SRC"
}

echo "== 前提 =="
lines '^散歩の前提 '
echo
echo "== 地図と経路の場 =="
lines '^(経路の場|地図のタイル|タイルを取得)'
echo
echo "== 店の取得 =="
lines '^店の取得'
echo "  通過: $(lines '^shop_pass' | wc -l | tr -d ' ') 軒"
echo
scripts/beacon_flips.sh "$SRC" "$FROM" | sed -n '/== ログが/,$p'
echo
echo "== ジェスチャの誤検出 =="
awk -F '\t' -v FROM="$FROM" -f scripts/shadow_rate.awk "$SRC"
echo
echo "== 頭の揺れ(普段の分布・p90 の中央値)=="
awk -F '\t' -v FROM="$FROM" -f scripts/head_sway.awk "$SRC"
echo
echo "== 画面と継続 =="
awk -F '\t' -v FROM="$FROM" -f scripts/background_gaps.awk "$SRC"
