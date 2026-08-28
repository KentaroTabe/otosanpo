#!/usr/bin/env bash
# 使い方: scripts/upload_tiles.sh <R2バケット名>
#
# maps/tiles/ の中身(タイルと meta.json)を Cloudflare R2 へ上げる。
#
# **このスクリプトは人が実行する。** wrangler のログイン(認証情報)が要り、
# 外向きの操作だから(CLAUDE.md / docs/12)。開発の流れから自動では呼ばれない。
#
# 事前:
#   1. npx wrangler login(初回のみ)
#   2. R2 のバケットを作り、**公開アクセスを有効にする**(アプリは認証を持たない)
#
# 転送量: 全国ぶんで 1.4〜2 GB・1 万数千ファイル。R2 の無料枠(容量 10 GB・
# Class A 100 万回/月)に収まる。途中で止めても、再実行すれば上書きで続きから揃う。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "使い方: scripts/upload_tiles.sh <R2バケット名>" >&2
  exit 1
fi
BUCKET="$1"

if [ ! -f maps/tiles/meta.json ]; then
  echo "maps/tiles/meta.json がありません。先に scripts/build_tiles.sh を実行してください" >&2
  exit 1
fi

mkdir -p logs
LOG=logs/upload_tiles.log
: > "$LOG"

TOTAL=$(ls maps/tiles | wc -l | tr -d ' ')
N=0
for f in maps/tiles/*; do
  NAME=$(basename "$f")
  N=$((N + 1))
  if ! npx wrangler r2 object put "$BUCKET/$NAME" --file "$f" --remote >> "$LOG" 2>&1; then
    echo "失敗: $NAME(logs/upload_tiles.log を確認)" >&2
    exit 1
  fi
  if [ $((N % 100)) -eq 0 ]; then
    echo "  $N / $TOTAL"
  fi
done

echo "完了: $N ファイルを $BUCKET へ上げました"
echo "アプリ側: config/parameters.json の map_download.base_url にバケットの公開 URL を入れる"
