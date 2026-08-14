#!/usr/bin/env bash
# 使い方: scripts/test.sh [シミュレータ名]
# 例:     scripts/test.sh "iPhone 17"
# ログは logs/test.log に出力し、結果サマリのみ表示する
set -euo pipefail
cd "$(dirname "$0")/.."

SIM="${1:-iPhone 17}"
mkdir -p logs
LOG=logs/test.log

if xcodebuild -project OtoSanpo.xcodeproj -scheme OtoSanpo \
    -destination "platform=iOS Simulator,name=${SIM}" test > "$LOG" 2>&1; then
  grep -E "Test Suite|Executed" "$LOG" | tail -n 20
  echo "テスト全緑"
else
  tail -n 80 "$LOG"
  exit 1
fi
