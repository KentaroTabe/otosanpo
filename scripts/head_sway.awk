# 「頭の揺れ」の行(10 秒ごとの要約)から、散歩全体の普段の揺れを出す(2026-10-31)。
# 使い方: awk -F '\t' -v FROM=<開始時刻の接頭辞> -f scripts/head_sway.awk <ログ>
#
# 閾値(pitch 16°・yaw 24°)に対して、普段の揺れがどれだけ近いかを見るためのもの。

function value(s, key,   i, rest) {
    i = index(s, key)
    if (i == 0) return ""
    rest = substr(s, i + length(key))
    if (match(rest, /^-?[0-9]+(\.[0-9]+)?/)) return substr(rest, 1, RLENGTH)
    return ""
}

function median(a, n,   i, j, t) {
    for (i = 2; i <= n; i++) {
        t = a[i]
        for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]
        a[j + 1] = t
    }
    return a[int((n + 1) / 2)]
}

FROM != "" && $1 < FROM { next }

$5 ~ /^頭の揺れ / {
    n++
    rest = substr($5, index($5, "yaw "))
    pitch[n] = value($5, "p90=") + 0
    yaw[n] = value(rest, "p90=") + 0
}

END {
    if (n == 0) { print "  頭の揺れの行がありません"; exit }
    printf "  区間 %d 個  pitch p90 の中央値 %.1f°(閾値 16)  yaw p90 の中央値 %.1f°(閾値 24)\n",
           n, median(pitch, n), median(yaw, n)
}
