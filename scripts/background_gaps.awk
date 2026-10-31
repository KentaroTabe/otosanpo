# 背面(画面消灯・ポケット)の間も位置更新が続いたかを見る(2026-10-31)。
# 使い方: awk -F '\t' -v FROM=<開始時刻の接頭辞> -f scripts/background_gaps.awk <ログ>
#
# 「画面: 前面 / 背面」の行で状態を区切り、fix の間隔の最大を状態ごとに出す。
# 背面で fix が止まっていれば、ポケットの中で案内が止まっていたことになる。

function seconds(ts,   t) {
    t = substr(ts, 12, 12)
    return substr(t, 1, 2) * 3600 + substr(t, 4, 2) * 60 + substr(t, 7) + 0
}

BEGIN { screen = "前面" }

FROM != "" && $1 < FROM { next }

$5 ~ /^画面: / {
    screen = substr($5, length("画面: ") + 1)
    changes++
    print "  " substr($1, 12, 8) "  " $5
}

$5 ~ /^fix / {
    now = seconds($1)
    if (last != "") {
        gap = now - last
        if (gap > maxGap[screen]) maxGap[screen] = gap
    }
    last = now
    count[screen]++
}

END {
    if (changes == 0) print "  画面の切り替わりはありません(ずっと前面、または古いログ)"
    for (s in count) printf "  %s: fix %d 件  最大の間隔 %.1f 秒\n", s, count[s], maxGap[s]
}
