#!/usr/bin/env bash
# 使い方: scripts/export_ipa.sh
#
# アーカイブから .ipa を書き出す。**アップロードはしない。**
# 書き出した .ipa は Transporter(Mac App Store の無料アプリ)へドラッグすれば上げられる。
#
# なぜこれがあるか: Xcode の Organizer は版によって配布の文言が変わる。
# .ipa と Transporter の組み合わせは UI の変化を受けにくいので、逃げ道として置く。
#
# **初回はアップル側に配布用の証明書が作られる**(-allowProvisioningUpdates)。
# 開発用とは別物で、開発ビルドでは作られない。
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE="build/OtoSanpo.xcarchive"
OUT="build/export"
OPTIONS="build/ExportOptions.plist"

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
LOG=logs/export_ipa.log

# method は Xcode 15.3 以降で名前が変わった(app-store → app-store-connect)。
# 新しい名前で失敗したら古い名前で試す
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>METHOD</string>
  <key>teamID</key><string>$TEAM</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

for method in app-store-connect app-store; do
  # method の行だけを書き換える(範囲を絞らないと destination の値まで巻き込む)
  sed -i '' -e "s|<key>method</key><string>[^<]*</string>|<key>method</key><string>$method</string>|" "$OPTIONS"
  rm -rf "$OUT"
  if xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
      -exportOptionsPlist "$OPTIONS" -allowProvisioningUpdates > "$LOG" 2>&1; then
    echo "書き出し成功(method=$method)"
    ls -lh "$OUT"/*.ipa 2>/dev/null || true
    echo
    echo "この .ipa を Transporter(Mac App Store の無料アプリ)へドラッグして上げてください"
    exit 0
  fi
  echo "method=$method では失敗。次を試します"
done

tail -n 40 "$LOG"
echo "書き出しに失敗しました" >&2
exit 1
