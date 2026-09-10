# scripts/list_logs.sh から呼ばれる。1 ファイル = 1 ブロックの要約を出す。
BEGIN {
  first = ""; last = ""
  hasSource = 0
  headSamples = 0; headUsed = 0
  music = 0
}
FNR == 1 { next }                      # 見出し行
$1 ~ /^[0-9]{4}-/ {
  if (first == "") first = $1
  last = $1
}
/頭方位/ { headSamples++ ; if ($0 ~ /使用=採用/) headUsed++ }
/音楽 距離=/ {
  music++
  if ($0 ~ /音源方位=/) hasSource++
  if (match($0, /基準=[^ \t]+/)) {
    key = substr($0, RSTART + 6, RLENGTH - 6)
    basis[key]++
  }
}
/開始しました|終了しました/ { }
END {
  printf "%s\n", FILENAME
  printf "  期間    %s 〜 %s (UTC)\n", first, last
  if (music == 0) {
    printf "  音楽    行なし\n"
  } else {
    printf "  ビルド  音源方位=%s (音楽 %d 行中 %d 行)\n", (hasSource > 0 ? "あり" : "なし"), music, hasSource
    line = "  基準    "
    for (k in basis) line = line sprintf("%s=%d ", k, basis[k])
    printf "%s\n", line
  }
  if (headSamples == 0) {
    printf "  頭方位  記録なし\n"
  } else {
    printf "  頭方位  %d 件 / 採用 %d 件 (%d%%)\n", headSamples, headUsed, int(headUsed * 100 / headSamples)
  }
}
