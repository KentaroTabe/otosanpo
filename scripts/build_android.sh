#!/usr/bin/env bash
# 使い方:
#   scripts/build_android.sh              経路データを同梱しない
#   scripts/build_android.sh 金沢市        maps/set/金沢市.json を APK に同梱する
#
# Android 版の APK を作る。**相手に渡すのはこの 1 ファイル**
# (iOS と違い、有料の開発者プログラムも端末登録も要らない。docs/10)。
#
# **都市を渡すと、その経路データごと配れる。**
# テスターが `Android/data/dev.otosanpo/files/` へファイルを置けなかったため
# (2026-08-28)。この場所は Android 11 以降、標準のファイルアプリから辿りにくい。
# 端末に置かれたファイルがあればそちらが優先されるので、同梱しても上書きにはならない。
#
# 事前に scripts/setup_android_sdk.sh を 1 回実行しておくこと。
set -euo pipefail
cd "$(dirname "$0")/.."

CITY="${1:-}"

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
# 同梱する都市ごとに名前を分ける。**どれを渡したか分からなくなるのを防ぐ**
if [ -n "$CITY" ]; then
  if [ ! -f "maps/set/${CITY}.json" ]; then
    echo "経路データがありません: maps/set/${CITY}.json" >&2
    echo "scripts/build_maps.sh で作ってください。あるものの一覧:" >&2
    ls maps/set/ >&2 || true
    exit 1
  fi
  OUT="dist/otosanpo-android-${CITY}.apk"
  # 空配列の展開は macOS の bash(3.2)だと set -u に引っかかるのでスカラで持つ
  GRADLE_ARG="-PbundledMap=${CITY}"
else
  OUT=dist/otosanpo-android.apk
  GRADLE_ARG=""
fi

# **毎回クリーンしてから作る。**
# 差分パッケージングは、外した資産のバイト列を APK に残す。
# 金沢市を同梱したあとに同梱なしで作り直すと、中央ディレクトリからは消えるのに
# ファイルは 6.8 MB のままだった(2026-08-28 実測。クリーン後は 3.3 MB)。
# **渡すつもりのない地図が混入する**ので、配布物を作る場面では速さより確実さを取る
if ! gradle -p android :app:clean :app:assembleDebug --console=plain \
    ${GRADLE_ARG:+"$GRADLE_ARG"} > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "Android のビルドに失敗しました" >&2
  exit 1
fi

grep -E "経路データ" "$LOG" || true

cp "$APK" "$OUT"

echo "ビルド成功"
ls -lh "$OUT"
echo "この APK を相手に渡し、「提供元不明のアプリ」を許可して開いてもらう"
echo "手順書(docs/11)も一緒に渡すこと"
if [ -n "$CITY" ]; then
  echo "**${CITY} の経路データを同梱済み。** 相手はファイルを置く必要がない"
fi
