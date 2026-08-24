#!/usr/bin/env bash
# 使い方: scripts/build_android.sh
#
# Android 版の APK を作る。**相手に渡すのはこの 1 ファイル**
# (iOS と違い、有料の開発者プログラムも端末登録も要らない。docs/10)。
#
# 事前に scripts/setup_android_sdk.sh を 1 回実行しておくこと。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p logs
LOG=logs/build_android.log
APK=android/app/build/outputs/apk/debug/app-debug.apk

if ! gradle -p android :app:assembleDebug --console=plain > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "Android のビルドに失敗しました" >&2
  exit 1
fi

echo "ビルド成功"
ls -lh "$APK"
echo "この APK を相手に渡し、「提供元不明のアプリ」を許可して開いてもらう"
