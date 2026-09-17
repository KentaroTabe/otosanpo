#!/usr/bin/env python3
"""config/parameters.json の head_mount.enabled を切り替える。

**JSON を丸ごと読み書きしない。** json.dump で書き戻すと整形の差が全体に散り、
diff が読めなくなる。head_mount ブロックの中の enabled 行だけを差し替える。

使い方(直接は呼ばず scripts/experiment.sh から):
    set_experiment.py <parameters.json> on|off|status
終了コード: 0 = 成功 / 1 = 失敗 / 2 = 使い方の誤り
status は現在値を "on" / "off" で標準出力に出す。
"""
import re
import sys

BLOCK = "head_mount"


def find_enabled_line(lines):
    """head_mount ブロックに入ってから最初の enabled 行の位置を返す。

    ブロックの入れ子は数えない。head_mount の直下に enabled があり、
    それより前に別の enabled が現れない構造を前提にする(現在の形)。
    見つからなければ None。
    """
    in_block = False
    for i, line in enumerate(lines):
        if not in_block:
            if re.search(r'"%s"\s*:\s*\{' % BLOCK, line):
                in_block = True
            continue
        if re.search(r'"enabled"\s*:\s*(true|false)', line):
            return i
        # ブロックが閉じたのに enabled が無い = 構造が変わっている
        if re.match(r"\s*\},?\s*$", line):
            return None
    return None


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    path, action = argv[1], argv[2]
    if action not in ("on", "off", "status"):
        print("action は on / off / status のいずれか", file=sys.stderr)
        return 2

    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    idx = find_enabled_line(lines)
    if idx is None:
        print("head_mount.enabled の行が見つかりません。"
              "config/parameters.json の構造が変わっていないか確認してください。",
              file=sys.stderr)
        return 1

    current = "on" if "true" in lines[idx] else "off"
    if action == "status":
        print(current)
        return 0

    if current == action:
        print(current)
        return 0

    want = "true" if action == "on" else "false"
    lines[idx] = re.sub(r'("enabled"\s*:\s*)(true|false)', r"\g<1>" + want, lines[idx])
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print(action)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
