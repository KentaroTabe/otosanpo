#!/usr/bin/env bash
# 使い方: scripts/setup.sh
# XcodeGen で OtoSanpo.xcodeproj を生成する(project.yml 変更後も再実行)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen > /dev/null 2>&1; then
  echo "xcodegen が見つかりません。'brew install xcodegen' を実行してください。" >&2
  exit 1
fi

if [ ! -f Support/Signing.xcconfig ]; then
  cp Support/Signing.example.xcconfig Support/Signing.xcconfig
  echo "Support/Signing.xcconfig を作成しました(Team ID は未設定)。"
fi

xcodegen generate
echo "OtoSanpo.xcodeproj を生成しました。"

if ! grep -qE '^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}[[:space:]]*$' Support/Signing.xcconfig; then
  echo "実機ビルドには Team ID が必要です。'scripts/set_team.sh' を実行してください。"
fi
