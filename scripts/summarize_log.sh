#!/usr/bin/env bash
# 使い方:
#   scripts/summarize_log.sh              field-logs/ の最新ログを要約する
#   scripts/summarize_log.sh <ファイル>   指定したログを要約する
#
# フィールドログは帰路ビーコンだけで数百行になるため、そのまま読むと
# 判断に要る行が埋もれる。閾値調整に使う行(提案・ジェスチャ振幅・方向の取得元)は
# 全件、量の多い行(ビーコン)は間引いて出す。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ge 1 ]; then
  SRC="$1"
else
  SRC=$(ls -t field-logs/*.tsv 2>/dev/null | head -n 1 || true)
fi

if [ -z "${SRC:-}" ] || [ ! -f "$SRC" ]; then
  echo "ログが見つかりません。先に scripts/import_log.sh で取り込んでください。" >&2
  exit 1
fi

echo "ファイル: $SRC"
awk -F'\t' -f scripts/summarize_log.awk "$SRC"
