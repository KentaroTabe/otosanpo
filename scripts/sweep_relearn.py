#!/usr/bin/env python3
"""見直しの窓(head_mount.relearn_*)を振って、再生の成績を並べる。

使い方: python3 scripts/sweep_relearn.py <ログ.tsv> [<ログ.tsv> ...]

なぜ要るか(2026-09-18): 取り付けのずれを「直近の証拠だけで作り直す」ようにしたが、
**窓が短い・閾値が小さいと、取り付けが変わっていないのに乗り換えて音の基準が跳ぶ**。
実測では 45°/40 秒で 10 分に 3 回乗り換えた(うち 2 回は不要)。
歩き直さずに値を決めるため、再生を総当たりで回す(CLAUDE.md のフィールドテスト方針)。

出す物: 組み合わせごとに「最初の乗り換え / 乗り換え回数 / 最終の学習値 / 使用可能の割合」。
**望ましいのは「最初の乗り換えが早く、回数が 1 回」**。
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = ROOT / "build-replay/Build/Products/Debug/otosanpo-replay"
BASE_CONFIG = ROOT / "config/parameters.json"
WORK = ROOT / "build-replay/sweep"

WINDOWS = [20, 30, 40, 60]
DISAGREE = [45, 60, 75, 90]


def variant(window: float, disagree: float) -> pathlib.Path:
    """窓と閾値だけ差し替えた設定を書き出す"""
    config = json.loads(BASE_CONFIG.read_text())
    config["head_mount"]["relearn_window_evidence_sec"] = window
    config["head_mount"]["relearn_min_disagree_deg"] = disagree
    WORK.mkdir(parents=True, exist_ok=True)
    path = WORK / f"w{window}-d{disagree}.json"
    path.write_text(json.dumps(config, ensure_ascii=False, indent=2))
    return path


def run(log: pathlib.Path, config: pathlib.Path) -> dict:
    out = subprocess.run([str(BINARY), str(log), str(config)],
                         capture_output=True, text=True).stdout
    swaps = re.findall(r"^\s+(\d+) 秒\s+→ ([-+][\d.]+)°$", out, re.MULTILINE)
    count = re.search(r"乗り換え (\d+) 回", out)
    learned = re.search(r"最終的な学習値: ([-+][\d.]+)°", out)
    usable = re.search(r"使用可能だった割合: (\d+)%", out)
    return {
        "swaps": swaps,
        "count": int(count.group(1)) if count else 0,
        "learned": learned.group(1) if learned else "成立せず",
        "usable": usable.group(1) if usable else "-",
    }


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    if not BINARY.exists():
        print(f"再生ツールがありません: {BINARY}\n"
              "先に scripts/replay_log.sh を 1 回実行してください。", file=sys.stderr)
        return 1
    for name in sys.argv[1:]:
        log = pathlib.Path(name)
        if not log.exists():
            print(f"ログがありません: {log}", file=sys.stderr)
            return 1
        print(f"== {log.name} ==")
        print("  窓   差   乗換  使用可能  最終の学習値  乗り換えの時刻と値")
        for window in WINDOWS:
            for disagree in DISAGREE:
                r = run(log, variant(window, disagree))
                trace = " / ".join(f"{t}s→{v}°" for t, v in r["swaps"][:4])
                if r["count"] > 4:
                    trace += f" …ほか {r['count'] - 4} 回"
                print(f"  {window:>3}s {disagree:>3}°  {r['count']:>3}回  {r['usable']:>6}%"
                      f"  {r['learned']:>10}°  {trace}")
        print("")
    print("読み方: 乗り換えは「装着で本当にずれた 1 回」だけが望ましい。")
    print("        2 回以上は、取り付けが変わっていないのに基準が跳んでいる疑い。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
