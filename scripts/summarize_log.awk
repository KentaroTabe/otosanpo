# フィールドログ(TSV: time / state / lat / lon / message)の要約。
# summarize_log.sh から呼ばれる。
#
# 出す基準:
# - 判断材料になる行(状態遷移・提案・ジェスチャ振幅・方向の取得元)は全件
# - 量が多く 1 行ずつには意味の薄い行(ビーコン)は間引き、傾向だけ示す

# "…pitch 振幅 12.3°(閾値 20)…" のように、キーの直後に来る数値を取り出す。
# awk の数値変換は先頭の数値部分だけを読むため、単位や括弧は無視される。
function numafter(s, key,   i) {
  i = index(s, key)
  if (i == 0) return ""
  return substr(s, i + length(key)) + 0
}

function hhmmss(iso) {
  return substr(iso, 12, 8)
}

NR == 1 && $1 == "time" { next }

{
  total++
  msg = $5
  if (first == "") first = $1
  last = $1

  if ($2 != prevState) {
    transitions[++nTrans] = hhmmss($1) "  " (prevState == "" ? "(開始)" : prevState) " -> " $2
    prevState = $2
  }
  stateCount[$2]++

  if (index(msg, "提案: ") == 1) {
    suggestions[++nSug] = hhmmss($1) "  " msg
  } else if (index(msg, "提案なし") == 1) {
    nNoSug++
  } else if (index(msg, "ビーコン ") == 1) {
    nBeacon++
    d = numafter(msg, "距離=")
    iv = numafter(msg, "間隔=")
    pan = numafter(msg, "pan=")
    if (nBeacon == 1 || d > beaconMaxD) beaconMaxD = d
    if (nBeacon == 1 || d < beaconMinD) beaconMinD = d
    beaconSumIv += iv
    if (nBeacon % beaconStride == 1 || beaconStride == 1) {
      beacons[++nBeaconShown] = hhmmss($1) "  " msg
    }
    # pan の符号が入れ替わった回数 = 左右が切り替わった回数
    panSign = (pan > 0.2) ? 1 : ((pan < -0.2) ? -1 : 0)
    if (panSign != 0 && prevPanSign != 0 && panSign != prevPanSign) nPanFlip++
    if (panSign != 0) prevPanSign = panSign
  } else if (index(msg, "帰路確認音") == 1) {
    nAck++
    if (nAck == 1) ackFirst = hhmmss($1)
    ackLast = hhmmss($1)
  } else if (index(msg, "誤検出候補") == 1) {
    nNear++
    p = numafter(msg, "pitch 振幅 ")
    y = numafter(msg, "yaw 振幅 ")
    if (p > nearPitchMax) nearPitchMax = p
    if (y > nearYawMax) nearYawMax = y
    nearLines[++nNearShown] = hhmmss($1) "  " msg
  } else if ($2 == "promptingReturn" && index(msg, "モーション ") == 1) {
    prompt[++nPrompt] = hhmmss($1) "  " msg
    p = numafter(msg, "pitch 振幅 ")
    y = numafter(msg, "yaw 振幅 ")
    if (p > promptPitchMax) promptPitchMax = p
    if (y > promptYawMax) promptYawMax = y
  } else {
    events[++nEvent] = hhmmss($1) "  [" $2 "] " msg
  }

  # 進行方向の取得元
  if (index(msg, "移動方向") > 0) nCourse++
  else if (index(msg, "端末コンパス") > 0) nCompass++
}

function section(title) {
  printf "\n== %s ==\n", title
}

function dump(arr, n, limit,   i, from) {
  from = (limit > 0 && n > limit) ? n - limit + 1 : 1
  if (from > 1) printf "  (先頭 %d 行省略)\n", from - 1
  for (i = from; i <= n; i++) printf "  %s\n", arr[i]
}

BEGIN { beaconStride = 10 }

END {
  if (total == 0) { print "行がありません"; exit }

  printf "期間: %s 〜 %s / %d 行\n", hhmmss(first), hhmmss(last), total
  printf "状態別行数:"
  for (s in stateCount) printf " %s=%d", s, stateCount[s]
  printf "\n"
  printf "進行方向の取得元: 移動方向=%d 端末コンパス=%d\n", nCourse, nCompass

  section("状態遷移")
  dump(transitions, nTrans, 0)

  section("イベント")
  dump(events, nEvent, 40)

  section("提案")
  printf "  鳴った=%d / 見送り(提案なし)=%d\n", nSug, nNoSug
  dump(suggestions, nSug, 0)

  section("応答待ち中のモーション振幅(ジェスチャ閾値の材料)")
  if (nPrompt == 0) {
    print "  記録なし(promptingReturn 中のモーション行が無い)"
  } else {
    printf "  最大 pitch 振幅=%.1f° / 最大 yaw 振幅=%.1f°\n", promptPitchMax, promptYawMax
    dump(prompt, nPrompt, 60)
  }

  section("歩行中の誤検出候補(閾値を下げられる余地)")
  printf "  件数=%d / 最大 pitch 振幅=%.1f° / 最大 yaw 振幅=%.1f°\n", nNear, nearPitchMax, nearYawMax
  dump(nearLines, nNearShown, 20)

  section("帰路")
  printf "  確認音=%d 回(%s 〜 %s)\n", nAck, (nAck ? ackFirst : "-"), (nAck ? ackLast : "-")
  printf "  ビーコン=%d 回 / 自宅まで 最遠=%.0fm 最近=%.0fm / 平均間隔=%.1fs / 左右の切替=%d 回\n",
         nBeacon, beaconMaxD, beaconMinD, (nBeacon ? beaconSumIv / nBeacon : 0), nPanFlip
  printf "  以下は %d 回に 1 行の間引き\n", beaconStride
  dump(beacons, nBeaconShown, 30)
}
