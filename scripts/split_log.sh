#!/usr/bin/env bash
# 使い方: scripts/split_log.sh <ログ.tsv>
#
# 複数の散歩が混ざったログを、散歩ごとのファイルに割る。
# 1 回ぶんなら何もしない。割った場合は元の混在ファイルを消し、
# <元の名前>-1.tsv, -2.tsv, … を同じ場所に作る(番号は古い順)。
#
# **端末側では削除しない、と決めた(2026-08-31・docs/05)。**
# ログは再生ベースの開発の唯一の実験データで、消えると取り返しがつかない。
# 混在の実害(取り違え・ひと手間)はこの分割が PC 側で吸収する。
#
# 散歩の切れ目は要約(summarize_log.sh)と同じ「idle → wandering」。
# ただし開始直前の idle 行(自宅設定・許可の状態など)は**次の散歩側に付ける**。
# その散歩を診断する材料のため。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?使い方: scripts/split_log.sh <ログ.tsv>}"
if [ ! -f "$SRC" ]; then
  echo "ファイルがありません: $SRC" >&2
  exit 1
fi

SESSIONS=$(awk -F'\t' 'NR>1 && prev=="idle" && $2=="wandering" { n++ } { prev=$2 } END { print n+0 }' "$SRC")
if [ "$SESSIONS" -le 1 ]; then
  echo "$SRC"
  exit 0
fi

BASE="${SRC%.tsv}"

awk -F'\t' -v base="$BASE" '
  NR == 1 { header = $0; next }
  {
    if ($2 == "idle") {
      # 散歩の合間の idle は保留し、次に始まる散歩へ付け替える
      pending[++np] = $0
      next
    }
    if ($2 == "wandering" && np > 0 && walked) {
      # 新しい散歩が始まった。ここまでを 1 ファイルに閉じる
      close_part()
    }
    flush_pending()
    body[++nb] = $0
    if ($2 == "wandering" || $2 == "returning") walked = 1
  }
  function flush_pending(   i) {
    for (i = 1; i <= np; i++) body[++nb] = pending[i]
    np = 0
  }
  function close_part(   f, i) {
    if (nb == 0) return
    f = base "-" (++part) ".tsv"
    print header > f
    for (i = 1; i <= nb; i++) print body[i] > f
    close(f)
    nb = 0
    walked = 0
  }
  END {
    flush_pending()
    close_part()
  }
' "$SRC"

# 割った結果を検分してから元を消す(行数が合わなければ元を残して止める)
TOTAL=$(awk 'END { print NR }' "$SRC")
PARTS=$(ls "${BASE}"-[0-9]*.tsv 2>/dev/null || true)
if [ -z "$PARTS" ]; then
  echo "分割に失敗しました(部品がありません): $SRC" >&2
  exit 1
fi
N=$(echo "$PARTS" | wc -l | tr -d ' ')
SUM=$(cat $PARTS | wc -l | tr -d ' ')
# 部品の合計 = 元の行数 − 1(元の見出し) + N(各部品の見出し)
if [ "$SUM" -ne $(( TOTAL - 1 + N )) ]; then
  echo "分割の行数が合いません(元 $TOTAL / 部品計 $SUM / $N 部品)。元を残します: $SRC" >&2
  exit 1
fi
rm "$SRC"

echo "$PARTS"