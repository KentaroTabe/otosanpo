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

# **アーカイブが通っても配布できるとは限らない。**
# xcodebuild archive は開発用の署名でも成功する。TestFlight へ上げる段(Organizer の
# Distribute App)で初めて配布用の証明書が要り、そこまで行ってから弾かれると分かりにくい。
# 有料プログラムに入っていれば「Apple Distribution」の証明書があるので、ここで見る。
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution"; then
  echo "配布用の証明書: あり"
  echo "Xcode で Window > Organizer を開き、Distribute App から TestFlight へ上げてください"
else
  echo
  echo "警告: **配布用の証明書(Apple Distribution)がありません。**" >&2
  echo "  このままでは Organizer の Distribute App で弾かれます。" >&2
  echo "  有料プログラムの反映と Team ID の設定を確認してください:" >&2
  echo "   1. developer.apple.com > Account > Membership details で Team ID を確認" >&2
  echo "   2. Xcode > Settings > Accounts でその Apple ID を選び、チーム一覧に出るか確認" >&2
  echo "      (出ない場合は加入処理がまだ完了していない。最大 48 時間かかることがある)" >&2
  echo "   3. scripts/set_team.sh <TEAM_ID>" >&2
  echo "   4. Xcode で一度ビルドすると配布用の証明書が作られる" >&2
fi
