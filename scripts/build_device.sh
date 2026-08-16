#!/usr/bin/env bash
# 使い方:
#   scripts/build_device.sh           接続中の iOS 実機へビルド → インストール → 起動
#   scripts/build_device.sh <UDID>    デバイスを明示指定
#
# ログは logs/build_device.log に出力し、失敗時のみ末尾を表示する。
# 無料(Personal Team)アカウントでは、実機を指定してビルドした時に初めてデバイスが
# チームへ登録され、プロビジョニングプロファイルが作られる。generic 指定では登録されない。
#
# デバッガを繋がずに起動するので、この後 USB を抜いてもアプリは動き続ける。
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=dev.otosanpo.OtoSanpo
DERIVED=build
APP="$DERIVED/Build/Products/Debug-iphoneos/OtoSanpo.app"

mkdir -p logs
LOG=logs/build_device.log

if [ $# -ge 1 ]; then
  UDID="$1"
else
  # xctrace の Devices セクションから実機の UDID(8桁-16桁)を拾う。Mac は UUID 形式なので除外される
  UDID=$(xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Simulators ==/ { exit } { print }' \
    | sed -n -E 's/.*\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})\).*/\1/p' \
    | head -n 1)
fi

if [ -z "${UDID:-}" ]; then
  echo "iOS 実機が見つかりません。iPhone を USB 接続し、ロック解除して「このコンピュータを信頼」を選んでください。" >&2
  exit 1
fi

echo "対象デバイス: $UDID"

if ! xcodebuild -project OtoSanpo.xcodeproj -scheme OtoSanpo \
    -destination "platform=iOS,id=${UDID}" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates build > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  exit 1
fi
echo "ビルド成功(署名 OK)"

if [ ! -d "$APP" ]; then
  echo "ビルド生成物が見つかりません: $APP" >&2
  exit 1
fi

xcrun devicectl device install app --device "$UDID" "$APP" >> "$LOG" 2>&1
echo "インストール完了"

xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >> "$LOG" 2>&1
echo "起動しました(この後 USB を抜いても動作します)"
