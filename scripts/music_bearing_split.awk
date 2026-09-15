# 使い方: awk -v within=30 -f scripts/music_bearing_split.awk <ログ.tsv>
#
# 音楽スポットの近くで、実際に鳴らした方位(`音源方位` = 直線と道の向きを混ぜたもの)を
# **直線の方位**と**道の向き(逆算)**に分けて並べる。
#
# 「スポットのそばで方位が 1 秒に 45〜51° 跳ぶ」(2026-09-14 の散歩)の原因が、
# 位置の誤差なのか、道の向きの切り替わりなのかを見分けるために用意した(2026-09-15)。
#
# スポットの中心はログに直接は無いので、「音楽スポット: Nm 先 方位 X°(鳴り始める地点から
# 置いた」の行と、その行の位置から復元する(距離 1 m・方位 1° に丸められているので、
# 誤差は 90 m 先で 1〜2 m 程度)。
#
# 道の向きは「混ぜた方位 = 直線と道の単位ベクトルを (1−w):w で足した向き」を逆に解いて出す。
# w は -v blend=(既定 0.5 = music_spot_route_blend)。混ぜた結果が真反対の打ち消しに
# 近い所では解けない(- と出す)。
BEGIN {
  FS = "\t"
  if (within == "") within = 30
  if (blend == "") blend = 0.5
  pi = atan2(0, -1)
  mPerDegLat = 111320.0
  have = 0
  printf "時刻      距離  直線方位  混ぜた方位  道の向き(逆算)  前の行からの変化(直線/混ぜた)\n"
}
$5 ~ /^音楽スポット: [0-9]+m 先 方位 [0-9]+°\(鳴り始める地点から置いた/ {
  n = split($5, tok, " ")
  dist = tok[2]; sub(/m$/, "", dist)
  brg = tok[5]; sub(/°.*$/, "", brg)
  lat0 = $3 + 0; lon0 = $4 + 0
  t = brg * pi / 180
  slat = lat0 + dist * cos(t) / mPerDegLat
  slon = lon0 + dist * sin(t) / (mPerDegLat * cos(lat0 * pi / 180))
  have = 1
  next
}
have && $5 ~ /^音楽 距離=/ {
  lat = $3 + 0; lon = $4 + 0
  d = haversine(lat, lon, slat, slon)
  if (d > within) { prevDirect = ""; next }
  direct = bearing(lat, lon, slat, slon)
  mixed = token($5, "音源方位"); sub(/°.*$/, "", mixed); mixed += 0
  # **2026-09-15 以降のログは、スポットの近くで混ぜる比を下げている**(近さ= の列)。
  # 混ぜる比 = blend × (1 − 近さ)。近さが 1(5 m 以内)なら道の向きは逆算できない
  near = token($5, "近さ")
  w = (near == "-" ? blend : blend * (1 - near))
  route = unblend(direct, mixed, w)
  dDirect = (prevDirect == "" ? "-" : sprintf("%+.0f", angdiff(direct, prevDirect)))
  dMixed = (prevDirect == "" ? "-" : sprintf("%+.0f", angdiff(mixed, prevMixed)))
  printf "%s  %4.0fm  %6.0f°   %6.0f°     %8s       %s / %s\n",
         substr($1, 12, 8), d, direct, mixed, route, dDirect, dMixed
  prevDirect = direct; prevMixed = mixed
}
function haversine(la1, lo1, la2, lo2,   p1, p2, dp, dl, h) {
  p1 = la1 * pi / 180; p2 = la2 * pi / 180
  dp = (la2 - la1) * pi / 180; dl = (lo2 - lo1) * pi / 180
  h = sin(dp / 2) ^ 2 + cos(p1) * cos(p2) * sin(dl / 2) ^ 2
  return 2 * 6371000 * atan2(sqrt(h), sqrt(1 - h))
}
function bearing(la1, lo1, la2, lo2,   p1, p2, dl, y, x) {
  p1 = la1 * pi / 180; p2 = la2 * pi / 180; dl = (lo2 - lo1) * pi / 180
  y = sin(dl) * cos(p2)
  x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
  return norm(atan2(y, x) * 180 / pi)
}
function norm(a) { a = a % 360; if (a < 0) a += 360; return a }
function angdiff(a, b,   d) { d = norm(a - b); if (d > 180) d -= 360; return d }
# 混ぜた方位 m と直線 a から、道の向き b を逆算する。
# m の向きの単位ベクトル × k = (1−w)·a + w·b。b は単位ベクトルなので、
# |k·m − (1−w)·a| = w を満たす k(> 0)を解き、b = (k·m − (1−w)·a) / w
function unblend(a, m, w,   ax, ay, mx, my, c, disc, k, bx, by) {
  if (w <= 0) return "-"
  ax = cos(a * pi / 180) * (1 - w); ay = sin(a * pi / 180) * (1 - w)
  mx = cos(m * pi / 180); my = sin(m * pi / 180)
  # |k·m − A|² = w²  →  k² − 2k(m·A) + |A|² − w² = 0
  c = mx * ax + my * ay
  disc = c * c - ((1 - w) ^ 2 - w * w)
  if (disc < 0) return "-"
  k = c + sqrt(disc)
  if (k <= 0) return "-"
  bx = (k * mx - ax) / w; by = (k * my - ay) / w
  return sprintf("%.0f°", norm(atan2(by, bx) * 180 / pi))
}
function token(msg, name,   k, tk, i, v) {
  k = split(msg, tk, " ")
  for (i = 1; i <= k; i++) {
    if (tk[i] ~ ("^" name "=")) { v = tk[i]; sub("^" name "=", "", v); return v }
  }
  return "-"
}
