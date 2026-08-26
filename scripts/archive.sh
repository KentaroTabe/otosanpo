#!/usr/bin/env bash
# 使い方: scripts/archive.sh
#
# TestFlight へ上げるためのアーカイブを作る。**アップロードはしない。**
# できた .xcarchive を Xcode の Organizer から配布する
# (Window > Organizer > Distribute App > TestFlight & App Store)。
#
# なぜここで止めるか: アップロードは Apple のアカウントに対する外向きの操作で、
# 認証情報も要る。**人が Xcode から行う**(実機への配備を手で行うのと同じ方針)。
#
# 事前に scripts/set_team.sh <TEAM_ID> で有料チームの Team ID を入れておくこと。
# 無料アカウントのままだとアーカイブは作れても配布できない。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p logs build
LOG=logs/archive.log
ARCHIVE="build/OtoSanpo.xcarchive"

# ビルド番号は毎回上げる。App Store Connect は同じ番号を 2 度受け付けない
BUILD_NUMBER="${1:-$(date +%Y%m%d%H%M)}"

echo "ビルド番号: $BUILD_NUMBER"
if ! xcodebuild -project OtoSanpo.xcodeproj -scheme OtoSanpo \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates archive > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "アーカイブに失敗しました" >&2
  exit 1
fi

echo "アーカイブ成功: $ARCHIVE"

# **署名に使われたプロファイルを確かめる。**
#
# 2026-08-26 に踏んだ罠: 有料プログラムへの加入は済んでいたのに、**無料時代に作られた
# プロファイルが期限内だったため使い回され**、アーカイブは成功するのに中身は
# 7 日で切れる開発用の署名だった。Team ID は個人加入だと**同じまま昇格する**ので、
# 「Team ID が変わっていない = 切り替わっていない」とは言えない。
#
# 見分け方は**期限**。有料チームの開発プロファイルは 1 年、無料は 7 日。
PROFILE="$ARCHIVE/Products/Applications/OtoSanpo.app/embedded.mobileprovision"
if [ -f "$PROFILE" ]; then
  PLIST=$(security cms -D -i "$PROFILE" 2>/dev/null || true)
  if [ -n "$PLIST" ]; then
    TEAM=$(printf '%s' "$PLIST" | plutil -extract TeamName raw - 2>/dev/null || echo "?")
    EXP=$(printf '%s' "$PLIST" | plutil -extract ExpirationDate raw - 2>/dev/null || echo "?")
    echo "署名: $TEAM / 期限 $EXP"
    LEFT=$(( ( $(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$EXP" +%s 2>/dev/null || echo 0) \
              - $(date +%s) ) / 86400 ))
    if [ "$LEFT" -gt 0 ] && [ "$LEFT" -lt 60 ]; then
      echo
      echo "警告: プロファイルの残りが ${LEFT} 日しかありません。" >&2
      echo "  **無料アカウント時代のものが使い回されている疑い**があります。" >&2
      echo "  次で作り直してから、もう一度アーカイブしてください:" >&2
      echo "    rm ~/Library/Developer/Xcode/UserData/Provisioning\\ Profiles/*.mobileprovision" >&2
      echo "    scripts/build_device.sh" >&2
      exit 1
    fi
  fi
fi

echo "Xcode で Window > Organizer を開き、Distribute App から TestFlight へ上げてください"
# 配布用の証明書(Apple Distribution)は**この時点では無くてよい**。
# 開発ビルドでは作られず、Organizer の Distribute App で Xcode が必要に応じて作る。
# 先に作っておきたい場合は Xcode > Settings > Accounts > チーム >
# Manage Certificates… > + > Apple Distribution。
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution"; then
  echo "(配布用の証明書はまだ無いが、Distribute App の途中で作られる)"
fi
