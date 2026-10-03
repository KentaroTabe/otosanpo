# 使い方: awk -f scripts/head_offset_error.awk <ログ.tsv>
#
# **取り付けのずれ(補正)が正しく学習できているか**を測る。
#
# 頭方位の行から「補正後の方位 − course」(= 差)を集め、その**円平均**を出す。
# 歩いている間、頭はおおむね進む方へ向くので、**差の平均は 0 付近になるはず**。
# 平均が大きく離れていれば、その分だけ**学習した補正がずれている**。
#
# なぜ要るか(2026-09-18): 「正面へ進むべき所で横だと判断していた」という報告。
# ログでは補正が 344° のまま固定され、差が +60〜160° に偏っていた。
# 検疫は門外割合 0.92〜1.00 で警告を出していたが、音楽はそれを無視して鳴っていた。
#
# 数値の取り出しに substr(RSTART,RLENGTH) を使わない(日本語のログではバイトで数えて切れる)。
BEGIN {
  FS = "\t"
  pi = atan2(0, -1)
  sx = 0; sy = 0; n = 0
  learnedFirst = ""; learnedLast = ""
  minDiff = 999; maxDiff = -999
}
$5 ~ /^頭方位 / {
  # **生の方位 − course が「本来あるべきずれ」。** 歩いている間、頭はおおむね進む方へ向くので、
  # この円平均が取り付けのずれの実測値になる(ログの `差` は絶対値なので符号が分からない)
  raw = token($5, "raw"); sub(/°$/, "", raw)
  course = token($5, "course"); sub(/°$/, "", course)
  if (course != "-" && course != "" && raw != "-") {
    t = (raw + 0 - course - 0) * pi / 180
    tx += cos(t); ty += sin(t); tn++
  }
  diff = token($5, "差")
  learned = token($5, "補正")
  if (learned != "-" && learned != "学習中") {
    if (learnedFirst == "") { learnedFirst = learned; learnedFirstAt = substr($1, 12, 8) }
    learnedLast = learned
    if (learned != prevLearned && prevLearned != "") changes++
    prevLearned = learned
  }
  if (diff == "-" || diff == "") next
  sub(/°$/, "", diff)
  d = diff + 0
  sx += cos(d * pi / 180); sy += sin(d * pi / 180); n++
  if (d < minDiff) minDiff = d
  if (d > maxDiff) maxDiff = d
  # 30° 刻みの分布
  b = int((d + 180) / 30); if (b > 11) b = 11; if (b < 0) b = 0
  bucket[b]++
}
END {
  if (n == 0) { print "頭方位の行に course との差がありません"; exit }
  mean = atan2(sy / n, sx / n) * 180 / pi
  r = sqrt((sx / n) ^ 2 + (sy / n) ^ 2)
  printf "学習した補正   最初 %s (%s) → 最後 %s(変化 %d 回)\n",
         learnedFirst, learnedFirstAt, learnedLast, changes + 0
  if (tn > 0) {
    trueOffset = atan2(ty / tn, tx / tn) * 180 / pi
    if (trueOffset < 0) trueOffset += 360
    tr = sqrt((tx / tn) ^ 2 + (ty / tn) ^ 2)
    err = trueOffset - (learnedLast + 0)
    err = err % 360; if (err > 180) err -= 360; if (err < -180) err += 360
    printf "実測のずれ     %.0f°(生の方位 − course の円平均・まとまり R=%.2f・標本 %d 件)\n",
           trueOffset, tr, tn
    printf "  → 学習した %s との差は **%+.0f°**。この分だけ音の向きがずれていた計算\n",
           learnedLast, err
  }
  printf "差(補正後の方位 − course・絶対値)  標本 %d 件\n", n
  printf "  円平均 %+.0f°(まとまり R=%.2f)  範囲 %+.0f° 〜 %+.0f°\n", mean, r, minDiff, maxDiff
  printf "  → **平均が 0 から離れた分が、学習した補正のずれ**(歩行中の頭は進む方を向くため)\n"
  printf "  → 補正を %+.0f° 直すと差が 0 付近になる計算\n", mean
  print  "分布(30° 刻み):"
  for (i = 0; i < 12; i++) {
    lo = i * 30 - 180
    printf "  %+4d°〜%+4d°  %5d  %s\n", lo, lo + 30, bucket[i] + 0, bar(bucket[i] + 0, n)
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
