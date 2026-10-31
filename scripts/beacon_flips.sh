#!/usr/bin/env bash
# 使い方: scripts/beacon_flips.sh <ログ> [開始時刻の接頭辞]
#   例: scripts/beacon_flips.sh field-logs/xxx.tsv 2026-10-31
#   1 つのログに複数の散歩が入っている時は、接頭辞より後の行だけを見る
#
# ログに記録された「ビーコンの指す方位」の跳びを数える(2026-10-03)。
#
# 再生ツール(`scripts/replay_log.sh`)は RouteField を作り直して測るが、
# **実機が実際に鳴らした向き**はログの中にある。両方を取って突き合わせるための口。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "使い方: scripts/beacon_flips.sh <ログ> [開始時刻の接頭辞]" >&2
  exit 1
fi

awk -F '\t' -v FROM="${2:-}" -f scripts/beacon_flips.awk "$SRC"
