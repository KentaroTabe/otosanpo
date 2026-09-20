# 使い方: awk -f scripts/head_swing.awk <ログ.tsv> [...]
#         awk -v thresh=90 -f scripts/head_swing.awk <ログ.tsv>
#
# **ログ区間ごとの方位の純変化(頭部モーション行の `Δ方位`)の分布**を出す。
#
# 厳密には「約 1 秒の区間の**両端の円差**」であり、区間長で割った角速度ではない
# (`head_mount.log_interval_sec` は 1.0 秒だが、実測の区間は 1.015 秒前後)。
# 区間内の往復や一周近い回転は見えない。件数を秒数と読み替えないこと。
#
# なぜ要るか(2026-09-18): スマホは頭の後ろに固定するので、装着は必ず「開始」の後になる。
# 手に持っている間に取り付けのずれを学習してしまう事故が実際に起きた
# (docs/13・学習 344° / 実測 95° / 差 106°)。
# 装着の動作は方位の急激な振れとして残っているので、**それを閾値で拾えるか**を
# 実データで確かめる。閾値を決める前に、通常歩行が同じ値に届かないことを示すのが目的。
#
# 出す物: 分布、閾値を超えた秒数とその割合、**連続して超えた最長の並び**(装着は続く・
# 曲がり角は続かない、という分離が成り立つかを見る)。
BEGIN {
  FS = "\t"
  if (thresh == "" || thresh + 0 <= 0) thresh = 60
}
FNR == 1 { file = FILENAME; sub(/.*\//, "", file); files[++nf] = file }
$5 ~ /^頭部モーション / {
  d = token($5, "Δ方位")
  if (d == "-") next
  sub(/°$/, "", d); sub(/^\+/, "", d)
  a = d + 0; if (a < 0) a = -a
  n++; byFile[file]++
  b = int(a / 20); if (b > 9) b = 9
  bucket[b]++
  if (a > max) { max = a; maxAt = substr($1, 12, 8); maxFile = file }
  if (a >= thresh) {
    over++; overByFile[file]++
    run++
    if (run > bestRun) { bestRun = run; bestRunEnd = substr($1, 12, 8); bestRunFile = file }
    if (run >= 2) runs2++
  } else {
    if (run > 0) runHist[run > 9 ? 9 : run]++
    run = 0
  }
}
END {
  if (n == 0) { print "頭部モーション行がありません(頭部固定で歩いたログのみ対象)"; exit }
  if (run > 0) runHist[run > 9 ? 9 : run]++
  printf "1 秒あたりの方位の純変化 |Δ方位|  標本 %d 件(%d ファイル)\n\n", n, nf
  print "分布(20° 刻み):"
  for (i = 0; i < 10; i++) {
    lo = i * 20
    printf "  %3d°〜%s  %6d  %5.1f%%  %s\n", lo, (i == 9 ? "    " : sprintf("%3d°", lo + 20)),
           bucket[i] + 0, 100 * (bucket[i] + 0) / n, bar(bucket[i] + 0, n)
  }
  printf "\n最大 %.0f°/s(%s・%s)\n", max, maxAt, maxFile
  printf "閾値 %d°/s 以上: %d 件(%.2f%%)\n", thresh, over + 0, 100 * (over + 0) / n
  printf "連続して超えた最長: %d 秒(%s まで・%s)\n", bestRun + 0, bestRunEnd, bestRunFile
  print  "連続した長さの分布(1 秒 = 単発・曲がり角はここに出る):"
  for (i = 1; i < 10; i++)
    if (i in runHist) printf "  %d 秒%s  %5d\n", i, (i == 9 ? " 以上" : "    "), runHist[i]
  print ""
  print "ファイルごと(閾値超え / 標本):"
  for (i = 1; i <= nf; i++) {
    f = files[i]
    if (byFile[f] + 0 == 0) continue
    printf "  %-40s %5d / %5d\n", f, overByFile[f] + 0, byFile[f]
  }
}
function bar(v, total,   k, s) {
  k = int(v * 40 / total)
  s = ""
  while (k-- > 0) s = s "#"
  return s
}
function token(msg, name,   k, tk, i, v) {
  k = split(msg, tk, " ")
  for (i = 1; i <= k; i++) {
    if (tk[i] ~ ("^" name "=")) { v = tk[i]; sub("^" name "=", "", v); return v }
  }
  return "-"
}
