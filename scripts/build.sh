#!/usr/bin/env bash
# 使い方: scripts/build.sh
# シミュレータ向けビルド。ログは logs/build.log に出力し、失敗時のみ末尾を表示する
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p logs
LOG=logs/build.log

if xcodebuild -project OtoSanpo.xcodeproj -scheme OtoSanpo \
    -destination 'generic/platform=iOS Simulator' build > "$LOG" 2>&1; then
  echo "ビルド成功"
else
  tail -n 60 "$LOG"
  exit 1
fi
