#!/usr/bin/env bash
# 使い方: scripts/clean.sh [シミュレータ名]
#
# 増分ビルドの生成物を捨てる。**テスト数が増えたはずなのに変わらない**・原因不明の起動失敗が
# 続く、といった時に挟む(CLAUDE.md「増分ビルドが古いまま通ることがある」)。
#
# 2026-09-15 に 3 度目を踏んだ: テストを 8 件足したのに 359 件のまま全緑になり、
# ログを見ると新しいテストは 1 件も走っていなかった(古いテストバイナリのまま通っていた)。
# **全緑でも件数が合わなければ、その緑は信じない。**
# ログは logs/clean.log に出力し、失敗時のみ末尾を表示する。
set -euo pipefail
cd "$(dirname "$0")/.."

SIM="${1:-iPhone 17}"
mkdir -p logs
LOG=logs/clean.log

if ! xcodebuild -project OtoSanpo.xcodeproj -scheme OtoSanpo \
    -destination "platform=iOS Simulator,name=${SIM}" clean > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "クリーンに失敗しました" >&2
  exit 1
fi
echo "クリーンしました(次のビルド・テストは全体を作り直します)"
