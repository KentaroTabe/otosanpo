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
  } else if (index(msg, "影検出") == 1) {
    nShadow++
    if (index(msg, "うなずき") > 0) nShadowNod++; else nShadowShake++
    shadowLines[++nShadowShown] = hhmmss($1) "  [" $2 "] " msg
  } else if (index(msg, "ビーコン(中央)") == 1) {
    nBeaconCenter++
  } else if (index(msg, "誤検出候補") == 1) {
    nNear++
    p = numafter(msg, "pitch 振幅 ")
    y = numafter(msg, "yaw 振幅 ")
    if (p > nearPitchMax) nearPitchMax = p
    if (y > nearYawMax) nearYawMax = y
    # 閾値 T の検出条件は「振幅 > 2T」。候補となる T ごとに、歩行中に何回
    # 条件を満たしたか(= 検出を常時有効にしたら何回誤検出したか)を数える
    for (t = 5; t <= 14; t++) {
      if (p > 2 * t) nearPitchOver[t]++
      if (y > 2 * t) nearYawOver[t]++
    }
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

  # 進行方向の取得元。保持値は「course が途切れていた区間」を意味するので分けて数える
  if (index(msg, "移動方向(保持)") > 0) nHeld++
  else if (index(msg, "移動方向") > 0) nCourse++
  else if (index(msg, "端末コンパス") > 0) nCompass++

  # 位置の水平精度(方向の判定には使っていないが、位置がどれだけ確かかを見る)
  if (index(msg, "水平精度=") > 0) {
    acc = numafter(msg, "水平精度=")
    if (acc >= 0) {
      nAcc++
      accSum += acc
      if (nAcc == 1 || acc > accMax) accMax = acc
      if (nAcc == 1 || acc < accMin) accMin = acc
    }
  }
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
  printf "進行方向の取得元: 移動方向=%d 移動方向(保持)=%d 端末コンパス=%d\n",
         nCourse, nHeld, nCompass
  if (nAcc > 0) {
    printf "位置の水平精度: 最良=%.0fm 平均=%.0fm 最悪=%.0fm(%d 件)\n",
           accMin, accSum / nAcc, accMax, nAcc
  } else {
    print "位置の水平精度: 記録なし(この版では出していない)"
  }

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

  section("影検出(応答待ち以外で検出器が反応した回数 = 誤検出の実測)")
  if (nShadow == 0) {
    print "  0 回。この閾値では歩行中に検出条件が成立しなかった"
  } else {
    printf "  %d 回(うなずき=%d / 首振り=%d)\n", nShadow, nShadowNod, nShadowShake
    dump(shadowLines, nShadowShown, 20)
  }

  section("歩行中の誤検出候補(閾値を下げられる余地)")
  printf "  件数=%d / 最大 pitch 振幅=%.1f° / 最大 yaw 振幅=%.1f°\n", nNear, nearPitchMax, nearYawMax
  if (nNear > 0) {
    print "  閾値を下げた場合に歩行中の動きが検出条件(振幅 > 閾値 x2)を満たす回数:"
    print "    閾値   pitch(うなずき)  yaw(首振り)"
    for (t = 14; t >= 5; t--) {
      printf "    ±%2d°        %5d 回        %5d 回\n", t, nearPitchOver[t], nearYawOver[t]
    }
    print "  ※ 記録は閾値の 0.7 倍を超えた区間だけ。それ未満の分布はこのログには無い"
  }
  dump(nearLines, nNearShown, 20)

  section("帰路")
  printf "  確認音=%d 回(%s 〜 %s)\n", nAck, (nAck ? ackFirst : "-"), (nAck ? ackLast : "-")
  printf "  中央で鳴らした(左右なし)=%d 回\n", nBeaconCenter
  printf "  ビーコン=%d 回 / 自宅まで 最遠=%.0fm 最近=%.0fm / 平均間隔=%.1fs / 左右の切替=%d 回\n",
         nBeacon, beaconMaxD, beaconMinD, (nBeacon ? beaconSumIv / nBeacon : 0), nPanFlip
  printf "  以下は %d 回に 1 行の間引き\n", beaconStride
  dump(beacons, nBeaconShown, 30)
}
