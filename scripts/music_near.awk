# 使い方: awk [-v within=30] -f scripts/music_near.awk <ログ.tsv>
#
# 音楽スポットの**近く**(距離 within m 以内・既定 30 m)で、1 秒ごとに
# 距離・向き・音量・定位の基準・音源方位と、その時点の GPS の水平精度・速度を並べる。
#
# 「スポットに近づいても最終的にどこにあるか分かりにくい」という報告(2026-09-15)を、
# 位置の誤差と照らして確かめるために用意した。スポットの近くでは、
# **GPS の誤差がスポットまでの距離と同じか大きい**ので、向きがどれだけ暴れていたかを見る。
#
# **数値の取り出しに substr(RSTART,RLENGTH) を使わない**(日本語のログではバイトで数えて
# 文字が切れる。agree_runs.awk で踏んだ)。空白で割ってから正規表現で頭と単位を削る。
BEGIN {
  FS = "\t"
  if (within == "") within = 30
  acc = "-"; spd = "-"
  printf "時刻      距離  向き    音量  基準        音源方位  水平精度  速度\n"
}
# 直前の位置更新の精度と速度を覚えておく
$5 ~ /^fix \[/ {
  acc = token($5, "水平精度")
  spd = token($5, "速度")
  next
}
$5 ~ /^音楽 距離=/ {
  d = token($5, "距離")
  sub(/m$/, "", d)
  if (d + 0 > within) next
  printf "%s  %4sm  %-6s  %s  %-10s  %-8s  %-8s  %s\n",
         substr($1, 12, 8), d, token($5, "向き"), token($5, "音量"),
         token($5, "基準"), token($5, "音源方位"), acc, spd
}
# 空白区切りの `<名前>=<値>` の値を返す(無ければ "-")
function token(msg, name,   n, tok, i, v) {
  n = split(msg, tok, " ")
  for (i = 1; i <= n; i++) {
    if (tok[i] ~ ("^" name "=")) {
      v = tok[i]
      sub("^" name "=", "", v)
      sub(/\]$/, "", v)
      return v
    }
  }
  return "-"
}
