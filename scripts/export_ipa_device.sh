#!/usr/bin/env bash
# 使い方: scripts/export_ipa_device.sh
#
# **TestFlight へ上げる前に、手元の iPhone で確かめるための書き出し。**
# scripts/archive.sh で作ったアーカイブ(= 配る中身そのもの)を、開発署名の .ipa にする。
#
# なぜ要るか(2026-09-17):
# - 配布用(app-store-connect)の .ipa は**端末へ直接入らない**。TestFlight を通すしかない
# - かといって scripts/build_device.sh は **Debug** なので、配布版で隠した開発用の項目
#   (頭の追従の確認・時間到来の発火・イベントログ)が出てしまい、「配る物の確認」にならない
#
# ここで書き出すのは**アーカイブと同じ Release の中身**で、署名だけ開発用に付け替えたもの。
# API キーもアーカイブに入ったものがそのまま入る(scripts/check_key.sh で確かめられる)。
#
# 端末へ入れるのは人が Xcode から行う(スクリプトは実機を操作しない方針):
#   1. iPhone を USB で繋ぎ、ロックを解除して「このコンピュータを信頼」を選ぶ
#   2. Xcode > Window > Devices and Simulators > 端末を選ぶ
#   3. Installed Apps の「+」で build/export-dev/OtoSanpo.ipa を選ぶ
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="build/OtoSanpo.xcarchive"
OUT="build/export-dev"
OPTIONS="build/ExportOptionsDev.plist"

if [ ! -d "$ARCHIVE" ]; then
  echo "アーカイブがありません。先に scripts/archive.sh を実行してください" >&2
  exit 1
fi

TEAM=$(grep DEVELOPMENT_TEAM Support/Signing.xcconfig | sed -E 's/.*= *//')
if [ -z "$TEAM" ]; then
  echo "Team ID が未設定です。scripts/set_team.sh <TEAM_ID> を先に実行してください" >&2
  exit 1
fi

mkdir -p build logs
LOG=logs/export_ipa_device.log

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

rm -rf "$OUT"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
    -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "書き出しに失敗しました" >&2
  exit 1
fi

echo "書き出し成功(method=development・中身はアーカイブと同じ Release)"
ls -lh "$OUT"/*.ipa
echo
echo "端末へ入れる手順(人が行う):"
echo "  1. iPhone を USB で繋ぎ、ロックを解除して「このコンピュータを信頼」を選ぶ"
echo "  2. Xcode > Window > Devices and Simulators > 端末を選ぶ"
echo "  3. Installed Apps の「+」で $OUT/OtoSanpo.ipa を選ぶ"
