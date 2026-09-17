# 使い方: awk -f scripts/music_summary.awk <ログ.tsv> [<ログ.tsv> ...]
#
# 音楽スポットが**鳴っている間**に、距離と音量がどう動いたかを散歩ごとにまとめる。
# 「音量の変化が感じられない」という報告を数字で確かめるために用意した(2026-09-11)。
#
# 出すもの:
#   置いた位置     出発点からの距離と方位(「音楽スポット: Nm 先」の行)
#   鳴り始め       その時点の距離・音量・基準、待った理由(頭の向き / 120 秒)
#   着いた時刻     鳴り始めより前に着いていないか(= 近づく間が無音でなかったか)
#   鳴っている間   距離と音量の最小・最大、音量の幅 [dB]、定位の基準の内訳
BEGIN { FS = "\t" }
FNR == 1 {
  if (NR > 1) report()
  file = FILENAME
  placed = ""; started = ""; startLine = ""; reached = ""; waited = ""
  playing = 0; n = 0
  minD = 1e9; maxD = -1; minG = 1e9; maxG = -1
  split("", basis)
  next
}
$5 ~ /^音楽スポット: [0-9]+m 先/ { placed = $5 }
$5 ~ /^音楽スポット: 頭の向きが定まらないまま/ { waited = "120 秒待って(頭の向きが定まらないまま)" }
$5 ~ /^音楽スポット: 鳴らし始めます/ { started = substr($1, 12, 8); startLine = $5; playing = 1 }
$5 ~ /^音楽スポット: 着いた/ { reached = substr($1, 12, 8) (playing ? "(鳴っている間)" : "(**鳴り始める前**)") }
$5 ~ /^音楽スポット: 終了/ { playing = 0 }
$5 ~ /^音楽 距離=/ && playing {
  d = field($5, "距離")
  g = field($5, "音量")
  if (d < 0 || g < 0) next
  n++
  if (d < minD) minD = d
  if (d > maxD) maxD = d
  if (g < minG) minG = g
  if (g > maxG) maxG = g
  # **substr(RSTART, RLENGTH) で切り出さない。** awk はそれをバイトで数えるので、
  # 日本語のラベルが途中で切れて文字化けする(agree_runs.awk で踏んだのと同じ)。
  # 語に割ってから正規表現で頭を削る
  k2 = split($5, tk, " ")
  for (j = 1; j <= k2; j++) {
    if (tk[j] ~ /^基準=/) { b = tk[j]; sub(/^基準=/, "", b); basis[b]++ }
  }
}
# 空白区切りの `<名前>=<数値><単位>` から数値を取り出す(単位は m / 無し)
function field(msg, name,   k, tok, i, v) {
  k = split(msg, tok, " ")
  for (i = 1; i <= k; i++) {
    if (tok[i] ~ ("^" name "=")) {
      v = tok[i]
      sub("^" name "=", "", v)
      sub(/m$/, "", v)
      if (v !~ /^[0-9.]+$/) return -1
      return v + 0
    }
  }
  return -1
}
function report(   line, k) {
  printf "%s\n", file
  printf "  置いた位置   %s\n", (placed == "" ? "(スポットなし)" : placed)
  if (started == "") {
    printf "  鳴り始め     鳴らなかった\n"
    return
  }
  printf "  鳴り始め     %s %s%s\n", started, startLine, (waited == "" ? "" : " / " waited)
  printf "  着いた       %s\n", (reached == "" ? "着いていない" : reached)
  if (n == 0) { printf "  鳴っている間 記録なし\n"; return }
  printf "  鳴っている間 %d 行 / 距離 %.0f〜%.0f m / 音量 %.2f〜%.2f(幅 %.1f dB)\n",
         n, minD, maxD, minG, maxG, (minG > 0 ? 20 * log(maxG / minG) / log(10) : 0)
  line = "  定位の基準   "
  for (k in basis) line = line k "=" basis[k] " "
  printf "%s\n", line
}
END { report() }
