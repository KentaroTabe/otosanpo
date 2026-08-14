#!/usr/bin/env bash
# 使い方:
#   scripts/pull_log.sh           接続中の実機からフィールドログを取り出す
#   scripts/pull_log.sh <UDID>    デバイスを明示指定
#
# 取り出し先は field-logs/field-log-<日時>.tsv(gitignore 対象)。
# 端末側のログは消さないので、テストの区切りではアプリ内の「ログを消去」を使う。
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID=dev.otosanpo.OtoSanpo
SRC=Documents/otosanpo-field-log.tsv
OUT_DIR=field-logs

if [ $# -ge 1 ]; then
  UDID="$1"
else
  UDID=$(xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Simulators ==/ { exit } { print }' \
    | sed -n -E 's/.*\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})\).*/\1/p' \
    | head -n 1)
fi

if [ -z "${UDID:-}" ]; then
  echo "iOS 実機が見つかりません。USB 接続してロックを解除してください。" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/field-log-$(date +%Y%m%d-%H%M%S).tsv"

xcrun devicectl device copy from \
  --device "$UDID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source "$SRC" \
  --destination "$OUT" \
  --user mobile > /dev/null

echo "取り出しました: $OUT"
wc -l < "$OUT" | tr -d ' ' | xargs -I{} echo "行数: {}"
