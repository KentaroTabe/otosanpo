#!/usr/bin/env python3
"""配布中の版と、これから配る APK の設定を突き合わせる(→ compare_shipped.sh)。

**項目の増減は差として扱わない。** 新しい項目でも既定と同じ値なら鳴る音は変わらない。
比べるのは「実際に鳴る音」と「実際の振る舞い」。
"""
import json
import sys

# 後から足した項目と、その「これが入る前と同じ振る舞いになる値」。
# ここに載っている項目は、値が既定どおりなら差とみなさない
DEFAULTS_EQUIVALENT_TO_OLD = {
    "harmonics": 1,        # 1 = 基音のみ = 純音(倍音を足す前と同じ)
    "harmonic_decay": None,  # harmonics が 1 なら音に影響しない
    "attack_ratio": 0.5,   # 0.5 = 左右対称の Hann 窓(非対称化する前と同じ)
}

# 音を鳴らさない設定(存在しても振る舞いが変わらないもの)。理由を添える
BENIGN_TOP_LEVEL = {
    "head_mount": "実験装置。enabled=false のうえ Android に実装が無い",
}


def flatten(d, path=""):
    out = {}
    for k, v in d.items():
        p = f"{path}.{k}" if path else k
        if isinstance(v, dict):
            out.update(flatten(v, p))
        else:
            out[p] = v
    return out


def main():
    ios_path, apk_path, tag, apk_name = sys.argv[1:5]
    ios = flatten(json.load(open(ios_path, encoding="utf-8")))
    apk = flatten(json.load(open(apk_path, encoding="utf-8")))

    print(f"配布中(iOS): {tag}")
    print(f"これから配る: {apk_name}")
    print()

    real = []      # 振る舞いが変わる差
    benign = []    # 変わらない差(項目が増えただけ)

    for key in sorted(set(ios) | set(apk)):
        a, b = ios.get(key, "(無し)"), apk.get(key, "(無し)")
        if a == b:
            continue
        leaf = key.split(".")[-1]
        top = key.split(".")[0]
        if a == "(無し)" and leaf in DEFAULTS_EQUIVALENT_TO_OLD:
            expected = DEFAULTS_EQUIVALENT_TO_OLD[leaf]
            if expected is None or b == expected:
                benign.append((key, f"新しい項目・既定値 {b}"))
                continue
            real.append((key, a, b))
            continue
        if a == "(無し)" and top in BENIGN_TOP_LEVEL:
            benign.append((key, BENIGN_TOP_LEVEL[top]))
            continue
        real.append((key, a, b))

    if real:
        print("!! 振る舞いが変わる差があります(機種で違う版になります):")
        for key, a, b in real:
            print(f"   {key}: 配布中={a} / これから={b}")
    else:
        print("振る舞いの差: **なし**(配布中の版と同じ動きになります)")

    if benign:
        print(f"\n(参考)項目は増えているが振る舞いは同じ: {len(benign)} 件")
        for key, why in benign[:4]:
            print(f"   {key} — {why}")
        if len(benign) > 4:
            print(f"   … ほか {len(benign) - 4} 件")

    sys.exit(1 if real else 0)


if __name__ == "__main__":
    main()
