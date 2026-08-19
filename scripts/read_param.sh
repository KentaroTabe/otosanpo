#!/usr/bin/env bash
# 使い方: scripts/read_param.sh route.map_radius_m
#
# config/parameters.json から値を 1 つ読む。スクリプト側に数値を書かないため
# (CLAUDE.md「数値・閾値はすべて config/parameters.json に置く」)。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "使い方: scripts/read_param.sh <キー(例: route.map_radius_m)>" >&2
  exit 1
fi

VALUE=$(jq -r ".$1" config/parameters.json)

if [ "$VALUE" = "null" ]; then
  echo "config/parameters.json に $1 がありません" >&2
  exit 1
fi

echo "$VALUE"
