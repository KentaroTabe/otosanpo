#!/usr/bin/env bash
# 使い方:
#   scripts/compare_shipped.sh [配布中のタグ] [APK]
#   例: scripts/compare_shipped.sh testflight-202608311200 dist/otosanpo-android-名古屋市.apk
#
# **APK に焼き込まれた設定**と、**iOS 配布版の設定**を突き合わせる。
#
# なぜ要るか(2026-09-02): 聴き比べの判断待ちだった音の変更が
# **Android の APK にだけ**入り、iOS のテスターとは違う音が鳴る状態で
# 配る寸前まで行った。利用者の指摘で止まった。
#
#   > 配布しているバージョンが機種によって違うという状況はあるべきではなく、
#   > 機種ごとの問題が起こるようになってからで良い
#
# **項目の増減そのものは差ではない。** 新しい項目でも、
# 既定と同じ値なら鳴る音は変わらない。ここでは「**実際に鳴る音**」を比べる。
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-testflight-202608311200}"
APK="${2:-}"

if [ -z "$APK" ]; then
  APK=$(ls -t dist/otosanpo-android-*.apk 2>/dev/null | head -n 1 || true)
fi
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "APK が見つかりません。scripts/build_android.sh <都市名> で作ってください" >&2
  exit 1
fi
if ! git rev-parse "$TAG" > /dev/null 2>&1; then
  echo "タグがありません: $TAG(配布中の版のタグを渡してください)" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git show "$TAG:config/parameters.json" > "$WORK/ios.json"
unzip -q -o "$APK" assets/parameters.json -d "$WORK"

python3 scripts/compare_shipped.py "$WORK/ios.json" "$WORK/assets/parameters.json" "$TAG" "$APK"
