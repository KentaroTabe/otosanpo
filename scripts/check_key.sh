#!/usr/bin/env bash
# 使い方: scripts/check_key.sh [構成]     例: scripts/check_key.sh Release
#
# Hot Pepper の API キーが「設定されているか」だけを報告する。
# **キーそのものは決して表示しない**(設定済み / 未設定 と、桁数だけ)。
#
# 2 か所を見る:
#   1. Support/Signing.xcconfig(.gitignore 済み。ここに書く)
#   2. ビルド済みアプリの Info.plist(実際に配布物へ入ったか)
#
# なぜ要るか(2026-09-17): キーが無くても店舗の機能は**黙って何もしない**ので、
# 配ってから「0 軒のまま」で気づくことになる。配る前にここで止める。
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-Release}"
PLACEHOLDER='$(HOTPEPPER_API_KEY)'
STATUS=0

CONFIG=Support/Signing.xcconfig
if [ ! -f "$CONFIG" ]; then
  echo "設定ファイルがありません: $CONFIG"
  echo "  scripts/setup.sh を実行すると手本から作られます"
  exit 1
fi

VALUE=$(sed -n -E 's/^[[:space:]]*HOTPEPPER_API_KEY[[:space:]]*=[[:space:]]*(.*)$/\1/p' "$CONFIG" \
        | tail -n 1 | tr -d '[:space:]')
if [ -z "$VALUE" ]; then
  echo "$CONFIG: APIキー 未設定"
  echo "  次の 1 行を足してください(値は伏せて構いません):"
  echo "    HOTPEPPER_API_KEY = 発行されたキー"
  STATUS=1
else
  echo "$CONFIG: APIキー 設定済み(${#VALUE} 文字)"
fi

APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -name OtoSanpo.app \
      -path "*${CONF}-iphonesimulator*" 2>/dev/null | head -n 1)
if [ -z "$APP" ]; then
  echo "ビルド済みアプリ($CONF): まだありません(scripts/build.sh などでビルドしてから確かめます)"
  exit "$STATUS"
fi

BUILT=$(plutil -extract HotPepperAPIKey raw -o - "$APP/Info.plist" 2>/dev/null || true)
if [ -z "$BUILT" ] || [ "$BUILT" = "$PLACEHOLDER" ]; then
  echo "ビルド済みアプリ($CONF): APIキー 未設定(差し込みの記号のまま)"
  echo "  → このまま配ると、店舗の機能は何も動きません"
  STATUS=1
else
  echo "ビルド済みアプリ($CONF): APIキー 設定済み(${#BUILT} 文字)"
fi

exit "$STATUS"
