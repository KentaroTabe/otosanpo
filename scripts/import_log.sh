#!/usr/bin/env bash
# 使い方:
#   scripts/import_log.sh          field-logs/inbox/ に置かれたログを取り込んで要約する
#   scripts/import_log.sh --usb    USB 接続の実機から直接取り出す(実機に触れるため既定では使わない)
#
# 想定する手順(実機も PC の他フォルダも操作しない経路):
#   1. iPhone のアプリ > フィールドログ > 「ログを書き出す」 > AirDrop で Mac へ
#   2. 受信したファイルを field-logs/inbox/ に入れる(Finder でドラッグ)
#   3. このスクリプトを実行
#
# 探索も書き込みも field-logs/ の中だけで完結する。
# ~/Downloads など PC の他のフォルダは読まない・変更しない。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=field-logs
INBOX="$OUT_DIR/inbox"

if [ "${1:-}" = "--usb" ]; then
  scripts/pull_log.sh
  scripts/summarize_log.sh
  exit 0
fi

mkdir -p "$INBOX"

SRC=$(ls -t "$INBOX"/*.tsv 2>/dev/null | head -n 1 || true)

if [ -z "${SRC:-}" ]; then
  echo "$INBOX にログがありません。" >&2
  echo "iPhone のアプリで「ログを書き出す」→ AirDrop で Mac へ送り、" >&2
  echo "受信したファイルをこのフォルダに入れてから再実行してください:" >&2
  echo "  $(pwd)/$INBOX" >&2
  exit 1
fi

# BSD date の -r はエポック秒を取るため、更新時刻は stat で取ってから渡す
MTIME=$(stat -f %m "$SRC")
OUT="$OUT_DIR/field-log-$(date -r "$MTIME" +%Y%m%d-%H%M%S).tsv"

# inbox から出す(移動)。残しておくと次回に前回のログを読んでしまう
mv "$SRC" "$OUT"

echo "取り込みました: $OUT"
echo "書き出し日時: $(date -r "$MTIME" '+%Y-%m-%d %H:%M:%S')"

# 古いファイルを取り違えると、直前のテストを見たつもりで前回のログを読むことになる
AGE_H=$(( ( $(date +%s) - MTIME ) / 3600 ))
if [ "$AGE_H" -ge 6 ]; then
  echo "警告: このファイルは $AGE_H 時間前のものです。今回のテストのものか確認してください。"
fi

scripts/summarize_log.sh "$OUT"
