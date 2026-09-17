# 使い方: awk [-v limit=40] [-v show=5] -f scripts/agree_runs.awk <ログ.tsv>
#
# **撤去済みの旧検疫(2026-09-10 まで)が要求していた条件**が、実際のログで
# 成立しえたかを測る。旧検疫は「course が取れていて、かつ差が閾値の内側」が
# **途切れず** regain_sec 続いたら採用し、course が nil の標本で窓を捨てていた。
# course は間欠的にしか取れないため、その条件が現実に成立しうるのかを
# 確かめるために用意した。結果は docs/13「連続一致が一度も成立せず…」の表。
#
# いまの検疫(割合方式)の評価には使わない。そちらは scripts/replay_log.sh で見る。
#
# limit: 差の閾値 [deg]。既定 40 = **旧方式の** distrust_deg
# show:  この秒数以上の区間を個別に並べる。既定 5 = **旧方式の** regain_sec
#        (どちらもいまの parameters.json には無い。旧方式を再現するための値として持つ)
#
# **数値の取り出しに substr(RSTART,RLENGTH) を使わない。** 日本語のログでは
# awk が RSTART/RLENGTH をバイトで数えるため 1 文字ぶんずれ、閾値を超えた標本を
# 0 と読んで「7 秒続いた」と誤って出した(2026-09-10)。正規表現で削る形にする。
BEGIN {
  # **TSV なのでタブ区切りを明示する。** 既定の空白区切りでは message 列が
  # 語ごとに割れ、$5 が「頭方位」だけになって差を読めない(2026-09-10 に踏んだ)
  FS = "\t"
  if (limit == "") limit = 40
  if (show == "") show = 5
  run = 0; best = 0; runs = 0; withCourse = 0; total = 0
}
$5 ~ /^頭方位/ {
  # **補正が成立していない間、検疫は 1 標本も進まない**(HeadMountFusion.ingest は
  # learned != nil のときだけ assess を呼ぶ)。その区間を数えると過大評価になる
  if ($0 ~ /補正=学習中/) { close_run(); next }
  total++
  t = substr($1, 12, 2) * 3600 + substr($1, 15, 2) * 60 + substr($1, 18, 2)
  if ($0 ~ /course=-°/) { close_run(); next }
  withCourse++
  diff = field($5, "差")
  if (diff <= limit) {
    if (run == 0) { runStart = t; runStamp = $1; run = 0.001 } else { run = t - runStart }
  } else {
    close_run()
  }
}
# 空白区切りの `<名前>=<数値><単位>` から数値を取り出す
function field(msg, name,   n, tok, i, v) {
  n = split(msg, tok, " ")
  for (i = 1; i <= n; i++) {
    if (tok[i] ~ ("^" name "=")) {
      v = tok[i]
      sub("^" name "=", "", v)
      sub(/°$/, "", v)
      return v + 0
    }
  }
  return -1
}
function close_run() {
  if (run <= 0) { run = 0; return }
  runs++
  if (run > best) best = run
  if (run >= show) printf "  %s から %.0f 秒\n", runStamp, run
  run = 0
}
END {
  close_run()
  printf "%s\n", FILENAME
  printf "  補正が成立していた 頭方位 %d 件 / うち course あり %d 件 (%d%%)\n",
         total, withCourse, (total ? int(withCourse * 100 / total) : 0)
  printf "  差 <= %d° が course 途切れなしで続いた最長区間: %.0f 秒(区間 %d 本)\n",
         limit, best, runs
}
