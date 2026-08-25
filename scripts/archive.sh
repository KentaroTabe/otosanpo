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
echo "Xcode で Window > Organizer を開き、Distribute App から TestFlight へ上げてください"
