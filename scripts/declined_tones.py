"""提案を断った後(分岐が背後に回った後)も鳴り続けた音を数える。

branch_backward_deg(135°)は候補を選ぶときの条件だが、鳴らし始めた後には効いていない。
「もうその道は背後だ」= 従わなかった、と判定できるはず。
"""
import re
import sys

path = sys.argv[1]
pat = re.compile(r"誘導 角まで=(\d+)m 鳴らす向き=([+-]?\d+)° 音量=([\d.]+)")
BACKWARD = 135

events, current = [], None
with open(path, encoding="utf-8") as f:
    for line in f:
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 5:
            continue
        msg = cols[4]
        if msg.startswith("誘導終了"):
            if current:
                current["end"] = msg[len("誘導終了"):]
                events.append(current)
                current = None
            continue
        m = pat.match(msg)
        if not m:
            continue
        if current is None:
            current = {"start": cols[0][11:19], "tones": [], "end": "(記録が切れた)"}
        current["tones"].append((int(m.group(1)), int(m.group(2))))
if current:
    events.append(current)

total_tones = sum(len(e["tones"]) for e in events)
wasted = 0
print(f"{len(events)} イベント / 音 {total_tones} 発\n")
print("分岐が背後(|相対| ≥ 135°)に回った後も鳴り続けた音:")
for i, e in enumerate(events, 1):
    first_back = next((k for k, (_, r) in enumerate(e["tones"]) if abs(r) >= BACKWARD), None)
    if first_back is None:
        continue
    after = len(e["tones"]) - first_back
    wasted += after
    print(f" {i:2d}. {e['start']}  {first_back + 1} 音目で背後になり、その後 {after} 発"
          f"(全 {len(e['tones'])} 発){e['end']}")

print(f"\n合計 {wasted} 発 / {total_tones} 発 ({wasted / total_tones * 100:.0f}%)"
      f" = 約 {wasted * 1.2:.0f} 秒ぶん")
