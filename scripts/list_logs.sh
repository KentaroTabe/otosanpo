#!/usr/bin/env bash
# 使い方: scripts/list_logs.sh [ファイル...]
#   引数なしなら field-logs/ 直下の *.tsv を新しい順に一覧する。
#
# 取り込んだログが「いつの・どのビルドの・どの散歩か」を 1 行で見分けるための道具。
# 同じ朝に別ビルドのログが混ざっていて取り違えかけたため用意した(2026-09-10)。
#
# 出す情報:
#   期間      先頭行と末尾行の時刻(UTC。JST は +9h)
#   ビルド    音楽行に `音源方位=` があるか = 直線と道を混ぜる版かどうか
#   頭方位    記録件数と、そのうち採用された割合
#   基準      音楽の定位に何を使ったか(頭部 / 進行 / 進行(保持))の内訳
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  FILES=()
  while IFS= read -r f; do
    FILES+=("$f")
  done < <(ls -t field-logs/*.tsv 2>/dev/null || true)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "field-logs/ に *.tsv がありません。" >&2
  exit 1
fi

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  awk -f scripts/list_logs.awk "$f"
done
