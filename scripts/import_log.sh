#!/usr/bin/env bash
# 使い方:
#   scripts/import_log.sh            field-logs/inbox/ のログを開発者のものとして取り込む
#   scripts/import_log.sh <ラベル>   テスターのものとして field-logs/testers/ に取り込む
#                                    (例: scripts/import_log.sh 文京区)
#   scripts/import_log.sh --usb      USB 接続の実機から直接取り出す(実機に触れるため既定では使わない)
#
# **テスターのログは開発者のものと別の置き場で管理する**(2026-08-30)。
# 混ぜると、後から詳細を調べるときに「誰の・どの端末の・どの地図の」歩きか
# 取り違える。開発者 = field-logs/ 直下、テスター = field-logs/testers/。
#
# 想定する手順(実機も PC の他フォルダも操作しない経路):
#   1. iPhone のアプリ > フィールドログ > 「ログを書き出す」 > AirDrop で Mac へ
#   2. 受信したファイルを field-logs/inbox/ に入れる(Finder でドラッグ)
#   3. このスクリプトを実行(テスターのログならラベルを付けて)
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

# ラベルがあればテスターのログ。置き場と名前を分ける
LABEL="${1:-}"
if [ -n "$LABEL" ]; then
  OUT_DIR="field-logs/testers"
  mkdir -p "$OUT_DIR"
fi

mkdir -p "$INBOX"

# **拡張子で決め打ちしない。** テスターから届いたログが `Untitled.txt` で、
# `*.tsv` しか見ていなかったため「ログがありません」になった(2026-08-30)。
# 経由(AirDrop・メール・メッセージ)によって名前も拡張子も変わる。
# **中身の見出し行で判定する。** 名前は相手の環境が決めるものなので当てにしない
SRC=""
for f in $(ls -t "$INBOX"/* 2>/dev/null || true); do
  [ -f "$f" ] || continue
  if head -n 1 "$f" | grep -q "^time	state	lat	lon	message$"; then
    SRC="$f"
    break
  fi
done

if [ -z "${SRC:-}" ]; then
  echo "$INBOX にログがありません。" >&2
  echo "iPhone のアプリで「ログを書き出す」→ AirDrop で Mac へ送り、" >&2
  echo "受信したファイルをこのフォルダに入れてから再実行してください:" >&2
  echo "  $(pwd)/$INBOX" >&2
  if [ -n "$(ls -A "$INBOX" 2>/dev/null || true)" ]; then
    echo "(ファイルはありますが、どれも見出し行が合いません。中身を確かめてください)" >&2
    ls -1 "$INBOX" >&2
  fi
  exit 1
fi

# BSD date の -r はエポック秒を取るため、更新時刻は stat で取ってから渡す
MTIME=$(stat -f %m "$SRC")
if [ -n "$LABEL" ]; then
  OUT="$OUT_DIR/${LABEL}-$(date -r "$MTIME" +%Y%m%d-%H%M%S).tsv"
else
  OUT="$OUT_DIR/field-log-$(date -r "$MTIME" +%Y%m%d-%H%M%S).tsv"
fi

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
