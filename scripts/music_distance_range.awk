# 音楽スポットまでの距離と音量の推移を、散歩の区間ごとに要約する(2026-10-26)。
#
# 使い方: awk -F '\t' -v FROM=<開始時刻の接頭辞> -f scripts/music_distance_range.awk <ログ>
#   FROM を渡すと、その時刻以降の行だけを見る(1 つのログに複数の散歩が入っている時)。
#
# 「音楽 距離=91m ... 音量=0.08 ...」の行から距離と音量を拾い、
# 最小・最大・最初・最後と、音量が下限に貼り付いていた割合を出す。
# 日本語を含むのでバイト位置の決め打ちはしない。index/substr の組で切る。

function value(s, key,   i, rest) {
    i = index(s, key)
    if (i == 0) return ""
    rest = substr(s, i + length(key))
    if (match(rest, /^-?[0-9]+(\.[0-9]+)?/)) return substr(rest, 1, RLENGTH)
    return ""
}

FROM != "" && $1 < FROM { next }

$5 ~ /^音楽 距離=/ {
    d = value($5, "距離=") + 0
    g = value($5, "音量=") + 0
    n++
    if (n == 1) { firstD = d; firstT = $1 }
    lastD = d; lastT = $1
    if (n == 1 || d < minD) { minD = d; minT = $1 }
    if (n == 1 || d > maxD) maxD = d
    if (n == 1 || g < minG) minG = g
    if (n == 1 || g > maxG) maxG = g
    gains[n] = g
}

END {
    if (n == 0) { print "音楽の行がありません"; exit }
    floor = 0
    for (i = 1; i <= n; i++) if (gains[i] <= minG + 0.001) floor++
    printf "音楽の行      %d 行\n", n
    printf "距離          最初 %dm(%s)→ 最後 %dm(%s)\n", firstD, firstT, lastD, lastT
    printf "最も近づいた  %dm(%s)\n", minD, minT
    printf "最も離れた    %dm\n", maxD
    printf "音量          %.2f 〜 %.2f\n", minG, maxG
    printf "下限に貼り付き %d 行 / %d(%.0f%%)\n", floor, n, 100 * floor / n
}
