# 使い方: awk -f scripts/music_reference_switch.awk <ログ.tsv>
#
# 音楽の**定位の基準が切り替わった瞬間**だけを抜き出し、その前後で
# 相対方位(向き)がどれだけ跳んだかを並べる。
#
# 「途中で音楽の向きの変化が離散的になった」(2026-09-18 の散歩)の原因を確かめるために用意した。
# 頭部固定が使えない間は進行方位へ退避する作りなので、**退避のたびに別の基準へ飛ぶ**。
#
# 数値の取り出しに substr(RSTART,RLENGTH) を使わない(日本語のログではバイトで数えて切れる)。
BEGIN {
  FS = "\t"
  printf "時刻      距離  基準の変化              向きの変化      音源方位\n"
  prevRef = ""; prevRel = ""; switches = 0; lines = 0
}
$5 ~ /^音楽 距離=/ {
  lines++
  ref = token($5, "基準")
  rel = token($5, "向き")
  if (prevRef != "" && ref != prevRef) {
    switches++
    d = token($5, "距離")
    jump = "-"
    if (prevRel != "中央" && rel != "中央") jump = sprintf("%+.0f°", angdiff(rel, prevRel))
    printf "%s  %4s  %-10s → %-10s  %-8s → %-8s  %s\n",
           substr($1, 12, 8), d, prevRef, ref, prevRel, rel, token($5, "音源方位")
    if (jump != "-") printf "            (跳び %s)\n", jump
  }
  prevRef = ref; prevRel = rel
}
END {
  printf "\n音楽の行 %d 行のうち、基準の切り替わりは %d 回\n", lines, switches
}
function angdiff(a, b,   x, y, d) {
  x = a + 0; y = b + 0
  d = (x - y) % 360
  if (d > 180) d -= 360
  if (d < -180) d += 360
  return d
}
function token(msg, name,   n, tok, i, v) {
  n = split(msg, tok, " ")
  for (i = 1; i <= n; i++) {
    if (tok[i] ~ ("^" name "=")) { v = tok[i]; sub("^" name "=", "", v); return v }
  }
  return "-"
}
