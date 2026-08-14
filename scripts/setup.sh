#!/usr/bin/env bash
# 使い方: scripts/setup.sh
# XcodeGen で OtoSanpo.xcodeproj を生成する(project.yml 変更後も再実行)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen > /dev/null 2>&1; then
  echo "xcodegen が見つかりません。'brew install xcodegen' を実行してください。" >&2
  exit 1
fi

xcodegen generate
echo "OtoSanpo.xcodeproj を生成しました。Xcode で開いて Signing の Team を設定してください。"
