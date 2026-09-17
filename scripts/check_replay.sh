#!/usr/bin/env bash
# 使い方: scripts/check_replay.sh
#
# 再生ツールの「fix の時刻」の扱い(受け入れ条件 F4)を、作った入力で確かめる。
#   - fix時刻= の無いログ: 不足している列と近似を明示し、「使用可能だった割合」を出さない
#   - fix時刻= のあるログ: 率を出し、不足の注記は出さない
#
# 再生ツールは実行形式なので単体テスト(scripts/test.sh)に入らない。
# そこで入力のログをその場で作って走らせ、出力を検める(2026-09-10 の 2 回目の検証で挙がった系列)。
# 作ったログも出力も logs/check_replay/ に置く(コミットしない)。
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=logs/check_replay
mkdir -p "$WORK"

# 2026-01-01T00:00:00Z を参照日時(2001-01-01T00:00:00Z)からの秒で表したもの。
# 25 年 × 365 日 + うるう日 6 日(2004〜2024)= 9131 日
BASE_REF=788918400

# 1 秒おきに fix 行と頭方位 行を 40 組書く。10 番目の fix は 1 ms 後にもう 1 行
# (同じ内容の fix 行が 2 本並ぶ、実ログで起きている形)
make_log() {
  local path="$1" with_fixtime="$2"
  {
    printf 'time\tstate\tlat\tlon\tmessage\n'
    printf '2026-01-01T00:00:00.000Z\twandering\t35.000000\t136.900000\t散歩を開始(20 分)\n'
    for i in $(seq 1 40); do
      local ts lat suffix row
      ts=$(printf '2026-01-01T00:00:%02d' "$i")
      lat=$(printf '35.%06d' $(( i * 10 )))
      suffix=""
      if [ "$with_fixtime" = 1 ]; then
        suffix=$(printf ' fix時刻=%d.000' $(( BASE_REF + i )))
      fi
      row="fix [course=0 速度=1.20m/s course精度=20 経過=0.1s 水平精度=5m]${suffix}"
      printf '%s.100Z\twandering\t%s\t136.900000\t%s\n' "$ts" "$lat" "$row"
      if [ "$i" = 10 ]; then
        printf '%s.101Z\twandering\t%s\t136.900000\t%s\n' "$ts" "$lat" "$row"
      fi
      printf '%s.500Z\twandering\t%s\t136.900000\t頭方位 raw=94.0° heading=94.0° course=0.0° 差=94.0° 状態=未検証 補正=学習中 R=0.00 使用=補正待ち\n' "$ts" "$lat"
    done
  } > "$path"
}

OLD="$WORK/no-fixtime.tsv"
NEW="$WORK/with-fixtime.tsv"
make_log "$OLD" 0
make_log "$NEW" 1

run_replay() {
  local log="$1" out="$2"
  if ! scripts/replay_log.sh "$log" > "$out" 2>&1; then
    tail -n 20 "$out"
    echo "再生に失敗しました: $log" >&2
    exit 1
  fi
}
run_replay "$OLD" "$WORK/no-fixtime.out"
run_replay "$NEW" "$WORK/with-fixtime.out"

FAIL=0
# $1 = 出力, $2 = 探す文字列, $3 = present / absent, $4 = 説明
check() {
  local found=absent
  if grep -q -- "$2" "$1"; then found=present; fi
  if [ "$found" = "$3" ]; then
    echo "  OK  $4"
  else
    echo "  NG  $4(「$2」が $found)"
    FAIL=1
  fi
}

echo "fix時刻= の無いログ:"
check "$WORK/no-fixtime.out" '不足している列: fix時刻=' present '不足している列を明示する'
check "$WORK/no-fixtime.out" '続けて並ぶ箇所が 1 組' present '同じ内容の fix 行が並ぶ箇所を数える'
check "$WORK/no-fixtime.out" '行を書いた時刻で代用' present '近似の方法を明示する'
check "$WORK/no-fixtime.out" '使用可能だった割合' absent '使用可能率を出さない'
check "$WORK/no-fixtime.out" '最初に学習が成立' present '学習の成立時刻は出す(近似として)'

echo "fix時刻= のあるログ:"
check "$WORK/with-fixtime.out" '使用可能だった割合' present '使用可能率を出す'
check "$WORK/with-fixtime.out" '不足している列: fix時刻=' absent '不足の注記を出さない'
check "$WORK/with-fixtime.out" 'fix時刻=(CLLocation.timestamp)を使っています' present 'fix の時刻の出どころを書く'

if [ "$FAIL" -ne 0 ]; then
  echo "再生ツールの検査に失敗しました(出力: $WORK/*.out)" >&2
  exit 1
fi
echo "再生ツールの検査: すべて OK"
