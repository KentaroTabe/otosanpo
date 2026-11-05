# 影検出(応答待ち以外で検出器が反応した回数)から、ジェスチャの誤検出率を出す(2026-10-26)。
#
# 使い方: awk -F '\t' -v FROM=<開始時刻の接頭辞> -f scripts/shadow_rate.awk <ログ>
#
# docs/04「影検出の実測」と同じ物差しで出す:
#   1 秒あたりの回数と、「応答までの 3 秒間に誤検出が起きる確率」(1 − exp(−率 × 3))
# 散策(wandering)と帰路(returning)の時間だけを母数にする(影検出はその 2 状態でだけ回る)。

FROM != "" && $1 < FROM { next }

function seconds(ts,   d, t, h, m, s) {
    # 2026-10-25T09:26:26.832Z → その日の 0 時からの秒(1 日の中の散歩しか見ないので足りる)
    t = substr(ts, 12, 12)
    h = substr(t, 1, 2) + 0
    m = substr(t, 4, 2) + 0
    s = substr(t, 7) + 0
    return h * 3600 + m * 60 + s
}

{
    now = seconds($1)
    if (prevState == "wandering" || prevState == "returning") {
        dt = now - prevTime
        if (dt > 0 && dt < 30) active += dt   # 長い空白(記録の途切れ)は母数に入れない
    }
    prevTime = now
    prevState = $2
}

$5 ~ /^影検出: うなずき/ { nods++ }
$5 ~ /^影検出: 首振り/ { shakes++ }

END {
    if (active <= 0) { print "散策・帰路の時間がありません"; exit }
    printf "母数(散策 + 帰路) %.0f 秒(%.1f 分)\n", active, active / 60
    rate(nods + 0, "うなずき(帰路開始)")
    rate(shakes + 0, "首振り(延長)")
}

function rate(n, label,   r) {
    r = n / active
    printf "  %-20s %3d 回  %.4f 回/秒  3 秒間に起きる確率 %.1f%%\n",
           label, n, r, 100 * (1 - exp(-r * 3))
}
