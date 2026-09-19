#!/usr/bin/env bash
# 使い方:
#   scripts/release_android.sh <タグ> <題名> <リリースノートのファイル>
#
# 例:
#   scripts/release_android.sh android-20260919 "Android テスター版 (2026-09-19)" notes.md
#
# Android のテスター版を GitHub Release として用意する(2026-09-02 から この形)。
#
# **下書きで作る。** 公開は人が GitHub の画面から行う —
# リポジトリは公開なので、Release も公開になる。
#
# **アセット名はローマ字にする。** 日本語のファイル名は、環境によって
# ダウンロード後に文字化けしたり、URL が読めなくなったりする。
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
TITLE="${2:-}"
NOTES="${3:-}"

if [ -z "$TAG" ] || [ -z "$TITLE" ] || [ -z "$NOTES" ]; then
  echo "使い方: scripts/release_android.sh <タグ> <題名> <リリースノートのファイル>" >&2
  exit 1
fi
if [ ! -f "$NOTES" ]; then
  echo "リリースノートがありません: $NOTES" >&2
  exit 1
fi

# **配る都市。** テスターが増えたらここへ足す(都市名 = maps/set/<都市名>.json)。
# 左が日本語のファイル名、右がアセットに使うローマ字
CITIES="名古屋市:nagoya 金沢市:kanazawa"

OUT=dist/release
rm -rf "$OUT"
mkdir -p "$OUT"

echo "テストを確かめます"
scripts/test_android.sh

echo "地図なしの APK を作ります"
scripts/build_android.sh
cp dist/otosanpo-android.apk "$OUT/otosanpo-android.apk"

for PAIR in $CITIES; do
  CITY="${PAIR%%:*}"
  ROMAJI="${PAIR##*:}"
  echo "$CITY の APK を作ります"
  scripts/build_android.sh "$CITY"
  cp "dist/otosanpo-android-${CITY}.apk" "$OUT/otosanpo-android-${ROMAJI}.apk"
done

# **タグは「いま居る枝」に付ける。**
# 既定のままだと既定ブランチ(main)にタグが付き、**この APK を作ったコードと
# 結びつかない**。あとから「どの版を配ったか」を辿れなくなる
BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "下書きの Release を作ります: $TAG($BRANCH に付ける)"
gh release create "$TAG" "$OUT"/*.apk \
    --draft --title "$TITLE" --notes-file "$NOTES" --target "$BRANCH"

echo "下書きができました。**公開は GitHub の画面から人が行うこと**"
gh release view "$TAG" --json url --jq .url
