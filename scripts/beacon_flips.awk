# ビーコンの指す向きの安定性を、**ログそのものから**数える(2026-10-03)。
#
# 再生ツール(Sources/Replay)は RouteField を作り直して測るが、
# **実機が実際に鳴らした向き**はログの「指す方位=」に入っている。
# 両者が食い違うなら、再生が実機を再現できていないということ。
#
# 使い方: scripts/beacon_flips.sh <ログ>
#
# 注意: TSV なので FS="\t" を必ず指定する(scripts/beacon_flips.sh が渡す)。
# 日本語を含むのでバイト位置の決め打ちはしない。index/substr の組で切る。

function value(s, key,   i, rest) {
    i = index(s, key)
    if (i == 0) return ""
    rest = substr(s, i + length(key))
    # 先頭の数値だけを取る(ここは必ず ASCII なので安全)
    if (match(rest, /^-?[0-9]+(\.[0-9]+)?/)) return substr(rest, 1, RLENGTH)
    return ""
}

function diff(a, b,   d) {
    d = (a - b) % 360
    if (d > 180) d -= 360
    if (d < -180) d += 360
    return d < 0 ? -d : d
}

BEGIN { prev = ""; prevTime = "" }

$5 ~ /^ビーコン 距離=/ {
    bearing = value($5, "指す方位=")
    course = value($5, "進行=")
    if (bearing == "") next
    total++
    state[$2]++

    if (course != "") {
        withCourse++
        if (diff(bearing, course) > 90) behind++
    }

    if (prev != "") {
        jump = diff(bearing, prev)
        if (jump > 90) {
            jumps++
            printf "  跳び %3.0f°  %s  %s° → %s°\n", jump, $1, prev, bearing
        }
        if (jump > 150) reversals++
    }
    prev = bearing
}

END {
    printf "\n== ログが記録した向き(実機そのもの)==\n"
    printf "  ビーコン        %d 発\n", total
    printf "  90°超の跳び     %d 回\n", jumps + 0
    printf "  150°超の跳び    %d 回\n", reversals + 0
    if (withCourse > 0)
        printf "  後ろを指した    %d 発 / %d(%.0f%%)\n",
               behind + 0, withCourse, 100 * behind / withCourse
    for (s in state) printf "  状態 %-12s %d 発\n", s, state[s]
}
