#!/usr/bin/env bash
# 使い方: scripts/build_demo.sh [出力先]
#
# 紹介用の音(語彙 5 種 + 散策・帰路の場面)を WAV で書き出す。
# **アプリと同じ Core のコード**で鳴らすので、紹介した音と実物が食い違わない。
#
# このアプリは画面を見ずに歩くのが前提で、スクリーンショットでは何も伝わらない。
# 人に見せるには音そのものを渡すしかない、というのがこのツールの理由。
#
# 座標・地図・経路は一切出力しない(出るのは波形だけ)。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build-demo}"
mkdir -p logs
LOG=logs/demo_build.log

if ! xcodebuild -project OtoSanpo.xcodeproj -scheme Demo \
    -destination 'platform=macOS' -derivedDataPath build-demo-tool build > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "紹介用ツールのビルドに失敗しました" >&2
  exit 1
fi

build-demo-tool/Build/Products/Debug/otosanpo-demo "$OUT"
