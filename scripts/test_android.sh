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
  echo "Android core テスト全緑"
else
  tail -n 60 "$LOG"
  echo "Android core テスト失敗" >&2
  exit 1
fi
