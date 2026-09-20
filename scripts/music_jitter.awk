# 使い方: awk -f scripts/music_jitter.awk <ログ.tsv>
#
# **音楽スポットの「向きの揺れ」が、どこから来ているかを距離ごとに測る。**
#
# なぜ要るか(2026-09-18): 利用者の報告「スポットが小刻みに移動している」。
# スポットの中心(`center`)は鳴り始めに決めて動かさないので、動いて聞こえる原因は
# 次の 2 つのどちらか(あるいは両方)しかない:
#
#   1. **音源方位**(自分 → スポットの世界方位)の揺れ … 位置(GPS)の誤差から来る。
#      近いほど大きく振れる(5 m 先で 3 m ずれれば 30° 以上動く)
#   2. **基準**(頭の向き)の揺れ … 磁力計の雑音と、実際の首振り
#
# 1 と 2 を分けないと対策を選べない(1 なら位置側を均す、2 なら基準側の話)。
# ログの `音源方位=` は 1、`向き=` は 1 と 2 の差。両方の 1 秒ごとの変化を距離帯ごとに出す。
#
# 数値の取り出しに substr(RSTART,RLENGTH) を使わない(日本語のログではバイトで数えて切れる)。
BEGIN {
  FS = "\t"
  split("5 10 20 40 80 100000", edge, " ")
  nb = 6
}
$5 ~ /^音楽 / {
  d = num(token($5, "距離"), "m")
  w = num(token($5, "音源方位"), "°")      # 世界方位(位置だけで決まる)
  r = token($5, "向き")
  if (r == "中央") r = ""
  rel = (r == "") ? "" : num(r, "°")
  t = clock($1)
  rows++
  # **経過秒で割って /s にする。** ログの間隔はちょうど 1 秒ではない(実測 1.015 秒前後)ので、
  # 行の差をそのまま「1 秒あたり」と読むと数%ずれる(2026-09-18 の合議で指摘)
  if (prevT != "" && t - prevT <= 2.5 && t - prevT > 0.05) {
    dt = t - prevT
    b = bucket(d)
    dw = adiff(w, prevW) / dt
    if (dw < 0) dw = -dw
    sumW[b] += dw; nW[b]++
    if (maxW[b] < dw) maxW[b] = dw
    if (rel != "" && prevRel != "") {
      dr = adiff(rel, prevRel) / dt
      if (dr < 0) dr = -dr
      sumR[b] += dr; nR[b]++
      if (maxR[b] < dr) maxR[b] = dr
    }
  }
  prevT = t; prevW = w; prevRel = rel
}
END {
  if (rows == 0) { print "音楽の行がありません"; exit }
  print "1 秒あたりの変化(距離帯ごと)"
  print ""
  print "  距離帯        件数   音源方位の変化(位置由来)   向きの変化(位置 + 頭)"
  print "                       平均      最大           平均      最大"
  for (i = 1; i <= nb; i++) {
    if (nW[i] + 0 == 0) continue
    lo = (i == 1) ? 0 : edge[i - 1]
    hi = (i == nb) ? 9999 : edge[i]
    if (i == nb) label = sprintf("%3d m 以上", lo)
    else label = sprintf("%3d〜%3d m", lo, hi)
    avgR = 0
    if (nR[i] + 0 > 0) avgR = sumR[i] / nR[i]
    printf "  %-12s %5d   %6.1f°  %6.1f°       %6.1f°  %6.1f°\n",
           label, nW[i], sumW[i] / nW[i], maxW[i], avgR, maxR[i] + 0
  }
  print ""
  print "読み方: **音源方位の変化が大きい距離帯が「スポットが動いて聞こえる」正体**。"
  print "        近いほど大きければ位置(GPS)の誤差。遠くても大きければ別の原因。"
}
function bucket(d,   i) {
  for (i = 1; i <= nb; i++) if (d < edge[i]) return i
  return nb
}
function adiff(a, b,   x) {
  x = (a - b) % 360
  if (x > 180) x -= 360
  if (x < -180) x += 360
  return x
}
function num(s, unit,   v) {
  v = s
  sub(unit "$", "", v)
  sub(/\(.*$/, "", v)
  sub(/^\+/, "", v)
  return v + 0
}
function clock(stamp,   hh, mm, ss) {
  if (stamp !~ /T[0-9][0-9]:/) return ""
  hh = substr(stamp, 12, 2); mm = substr(stamp, 15, 2); ss = substr(stamp, 18, 6)
  return hh * 3600 + mm * 60 + ss
}
function token(msg, name,   k, tk, i, v) {
  k = split(msg, tk, " ")
  for (i = 1; i <= k; i++) {
    if (tk[i] ~ ("^" name "=")) { v = tk[i]; sub("^" name "=", "", v); return v }
  }
  return "-"
}
