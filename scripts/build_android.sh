#!/usr/bin/env bash
# 使い方: scripts/build_android.sh
#
# Android 版の APK を作る。**相手に渡すのはこの 1 ファイル**
# (iOS と違い、有料の開発者プログラムも端末登録も要らない。docs/10)。
#
# 事前に scripts/setup_android_sdk.sh を 1 回実行しておくこと。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p logs dist
LOG=logs/build_android.log

# **android/local.properties は git のブランチ切り替えで消える。**
# 追跡外でも、android/ ごと消えるときに巻き込まれる(2026-08-27・28 に 3 回踏んだ)。
# SDK 本体があるなら黙って書き直す。無い場合だけ setup_android_sdk.sh を促す
SDK_ROOT="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
if [ ! -f android/local.properties ]; then
  if [ -d "$SDK_ROOT/platforms" ]; then
    echo "sdk.dir=$SDK_ROOT" > android/local.properties
    echo "android/local.properties が無かったので書き直しました"
  else
    echo "Android SDK が見つかりません。scripts/setup_android_sdk.sh を先に実行してください" >&2
    exit 1
  fi
fi

APK=android/app/build/outputs/apk/debug/app-debug.apk
# **渡す用の複製は dist/ に置く。**
# gradle の出力先は android/app/build/... と深く、探しにくい。
# さらに **git のブランチ切り替えで android/ ごと消える**ことがある
# (追跡外のファイルでも、ディレクトリごと消えるときに巻き込まれる)。
# dist/ はどの枝にも属さないので残る
OUT=dist/otosanpo-android.apk

if ! gradle -p android :app:assembleDebug --console=plain > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "Android のビルドに失敗しました" >&2
  exit 1
fi

cp "$APK" "$OUT"

echo "ビルド成功"
ls -lh "$OUT"
echo "この APK を相手に渡し、「提供元不明のアプリ」を許可して開いてもらう"
echo "手順書(docs/11)も一緒に渡すこと"
