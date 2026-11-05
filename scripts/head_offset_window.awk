# 使い方: awk -f scripts/head_offset_window.awk <ログ.tsv>
#         awk -v win=30 -f scripts/head_offset_window.awk <ログ.tsv>   # 窓を 30 秒にする
#
# **取り付けのずれが「いつ」変わったか**を測る。head_offset_error.awk は散歩全体の
# 円平均を 1 つ出すだけなので、「最初は合っていたが途中でずれた」を区別できない。
#
# なぜ要るか(2026-09-18): スマホは**頭の後ろに固定するので、装着は必ず「開始」の後**になる。
# つまり最初の数十秒は手に持った状態のずれを学習してしまう。
# それが起きていたかどうかは、ずれの円平均を時間窓ごとに並べれば分かる。
#
# 併せてスマホの姿勢(頭部モーション行の `重力xyz`)の窓平均も出す。
# **実測では装着の目印にならなかった**(2026-09-18): 装着前後とも +0.98/+0.13/+0.07 で、
# 手に持つ向きと頭に載せた向きがほぼ同じだった。姿勢に頼る案を否定した記録として残す。
#
# 数値の取り出しに substr(RSTART,RLENGTH) を使わない(日本語のログではバイトで数えて切れる)。
BEGIN {
  FS = "\t"
  pi = atan2(0, -1)
  if (win == "" || win + 0 <= 0) win = 60
}
{
  ts = clock($1)
  if (ts == "") next
  if (t0 == "") t0 = ts
  w = int((ts - t0) / win)
  if (w > lastW) lastW = w
}
$5 ~ /^頭方位 / {
  raw = token($5, "raw"); sub(/°$/, "", raw)
  course = token($5, "course"); sub(/°$/, "", course)
  learned = token($5, "補正")
  if (learned != "-" && learned != "学習中") learnedIn[w] = learned
  if (course == "-" || course == "" || raw == "-") next
  d = (raw + 0 - course - 0) * pi / 180
  sx[w] += cos(d); sy[w] += sin(d); n[w]++
}
$5 ~ /^頭部モーション / {
  g = token($5, "重力xyz")
  if (g == "-") next
  if (split(g, xyz, "/") != 3) next
  gx[w] += xyz[1]; gy[w] += xyz[2]; gz[w] += xyz[3]; gn[w]++
}
END {
  if (t0 == "") { print "時刻を読める行がありません"; exit }
  printf "窓 %d 秒ごとの「生の方位 − course」の円平均(= 取り付けのずれの実測値)\n\n", win
  print  "経過      標本  実測のずれ  まとまりR  学習した補正   スマホの姿勢(重力xyz の窓平均)"
  for (i = 0; i <= lastW; i++) {
    printf "%5s  ", mmss(i * win)
    if (n[i] + 0 == 0) {
      printf "%5s  %10s  %9s", "0", "-", "-"
    } else {
      m = atan2(sy[i] / n[i], sx[i] / n[i]) * 180 / pi
      if (m < 0) m += 360
      r = sqrt((sx[i] / n[i]) ^ 2 + (sy[i] / n[i]) ^ 2)
      printf "%5d  %9.0f°  %9.2f", n[i], m, r
    }
    printf "  %12s", (i in learnedIn) ? learnedIn[i] : "-"
    if (gn[i] + 0 > 0)
      printf "   %+.2f/%+.2f/%+.2f", gx[i] / gn[i], gy[i] / gn[i], gz[i] / gn[i]
    print ""
  }
  print ""
  print "読み方: 実測のずれが窓をまたいで大きく動いていれば、その間に取り付けが変わった"
  print "        (= 装着・付け直し)。学習した補正がその前の窓の値で固定されていれば、"
  print "        以降ずっとその差のぶん音の向きがずれる。"
}
function clock(stamp,   hh, mm, ss) {
  if (stamp !~ /T[0-9][0-9]:/) return ""
  hh = substr(stamp, 12, 2); mm = substr(stamp, 15, 2); ss = substr(stamp, 18, 6)
  return hh * 3600 + mm * 60 + ss
}
function mmss(sec) {
  return sprintf("%d:%02d", int(sec / 60), sec % 60)
}
function token(msg, name,   k, tk, i, v) {
  k = split(msg, tk, " ")
  for (i = 1; i <= k; i++) {
    if (tk[i] ~ ("^" name "=")) { v = tk[i]; sub("^" name "=", "", v); return v }
  }
  return "-"
}
