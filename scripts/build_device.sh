#!/usr/bin/env bash
# 使い方:
#   scripts/build_device.sh           接続中の iOS 実機を自動検出してビルド
#   scripts/build_device.sh <UDID>    デバイスを明示指定してビルド
#
# 署名設定が通っているかの確認に使う。ログは logs/build_device.log に出力し、失敗時のみ末尾を表示する。
# 無料(Personal Team)アカウントでは、実機を指定してビルドした時に初めてデバイスが
# チームへ登録され、プロビジョニングプロファイルが作られる。generic 指定では登録されない。
set -euo pipefail
cd "$(dirname "$0")/.."

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

if xcodebuild -project OtoSanpo.xcodeproj -scheme OtoSanpo \
    -destination "platform=iOS,id=${UDID}" -allowProvisioningUpdates build > "$LOG" 2>&1; then
  echo "実機向けビルド成功(署名 OK)"
else
  tail -n 40 "$LOG"
  exit 1
fi
