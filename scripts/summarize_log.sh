#!/usr/bin/env bash
# 使い方:
#   scripts/summarize_log.sh                 field-logs/ の最新ログ全体を要約する
#   scripts/summarize_log.sh --last          そのうち最後の散歩(1 セッション)だけを要約する
#   scripts/summarize_log.sh <ファイル>      指定したログを要約する
#   scripts/summarize_log.sh --last <ファイル>
#
# フィールドログは帰路ビーコンだけで数百行になるため、そのまま読むと
# 判断に要る行が埋もれる。閾値調整に使う行(提案・ジェスチャ振幅・方向の取得元)は
# 全件、量の多い行(ビーコン)は間引いて出す。
#
# アプリ内の「ログを消去」を押し忘れると前回の散歩が残るため、
# セッションが複数あるときは警告し、--last で最後の 1 回に絞れるようにしている。
set -euo pipefail
cd "$(dirname "$0")/.."

ONLY_LAST=0
if [ "${1:-}" = "--last" ]; then
  ONLY_LAST=1
  shift
fi

if [ $# -ge 1 ]; then
  SRC="$1"
else
  SRC=$(ls -t field-logs/*.tsv 2>/dev/null | head -n 1 || true)
fi

if [ -z "${SRC:-}" ] || [ ! -f "$SRC" ]; then
  echo "ログが見つかりません。先に scripts/import_log.sh で取り込んでください。" >&2
  exit 1
fi

# 散歩の開始 = 状態が idle から wandering に変わった行
SESSIONS=$(awk -F'\t' 'NR>1 && prev=="idle" && $2=="wandering" { n++ } { prev=$2 } END { print n+0 }' "$SRC")

echo "ファイル: $SRC"
echo "含まれる散歩: ${SESSIONS} 回"

WORK="$SRC"
if [ "$ONLY_LAST" = "1" ] && [ "$SESSIONS" -gt 1 ]; then
  WORK=$(mktemp -t otosanpo-log)
  trap 'rm -f "$WORK"' EXIT
  awk -F'\t' -v out="$WORK" '
    NR == 1 { header = $0; next }
    prev == "idle" && $2 == "wandering" { start = NR }
    { prev = $2; line[NR] = $0; last = NR }
    END {
      print header > out
      for (i = start; i <= last; i++) print line[i] > out
    }
  ' "$SRC"
  echo "(--last: 最後の 1 回だけを対象にしています)"
elif [ "$SESSIONS" -gt 1 ]; then
  echo "警告: 複数の散歩が混ざっています。最後の 1 回だけ見るには --last を付けてください。"
fi

awk -F'\t' -f scripts/summarize_log.awk "$WORK"
