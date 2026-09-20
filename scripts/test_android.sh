#!/usr/bin/env bash
# 使い方: scripts/test_android.sh
#
# Android 版の core(純粋ロジック)を JVM で検証する。
# **Android SDK は要らない**(docs/10)。ログは logs/ に落とし、失敗時だけ末尾を出す。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p logs
LOG=logs/test_android.log

if gradle -p android :core:test --console=plain > "$LOG" 2>&1; then
  grep -E "BUILD SUCCESSFUL|tests completed" "$LOG" || true
  # **件数を必ず出す。** iOS 側で「増やしたはずのテストが実行されない」古いビルドに
  # 2 度やられている(CLAUDE.md)。数が変わらないことに気づけるようにする
  RESULTS=android/core/build/test-results/test
  if [ -d "$RESULTS" ]; then
    COUNT=$(grep -ho 'tests="[0-9]*"' "$RESULTS"/*.xml | grep -o '[0-9]*' \
            | awk '{ n += $1 } END { print n + 0 }')
    echo "テスト件数: $COUNT"
  fi
  echo "Android core テスト全緑"
else
  tail -n 60 "$LOG"
  echo "Android core テスト失敗" >&2
  exit 1
fi
