#!/usr/bin/env bash
# 使い方: scripts/setup_android_sdk.sh
#
# Android SDK(コマンドライン版)を用意する。Android Studio は入れない。
# APK を作るのに要るのは platform / build-tools / platform-tools の 3 つだけ。
#
# **ライセンスへの同意を含む**(2026-08-21 に利用者の承認を得て自動化した)。
# 同意しないと sdkmanager はパッケージを落とさない。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_ROOT="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
API="${1:-35}"
BUILD_TOOLS="${2:-35.0.0}"

if ! command -v sdkmanager > /dev/null; then
  echo "sdkmanager が見つかりません。brew install --cask android-commandlinetools を先に実行してください" >&2
  exit 1
fi

mkdir -p logs
LOG=logs/android_sdk.log

echo "SDK の場所: $SDK_ROOT"
yes | sdkmanager --sdk_root="$SDK_ROOT" --licenses > "$LOG" 2>&1 || true
sdkmanager --sdk_root="$SDK_ROOT" \
  "platform-tools" "platforms;android-${API}" "build-tools;${BUILD_TOOLS}" >> "$LOG" 2>&1

echo "sdk.dir=$SDK_ROOT" > android/local.properties
echo "android/local.properties を書きました(gitignore 対象)"
echo "入っているもの:"
ls "$SDK_ROOT/platforms" "$SDK_ROOT/build-tools" 2>/dev/null || true
