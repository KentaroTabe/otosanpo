"""各誘導イベントの序盤を並べ、どこから左右が付くかを見る。

使い方: scripts/guidance_shape.py <ログファイル>

「案内音が向きを持っていない」という体感の裏を取るための道具。
要約(summarize_log)は 1 イベント 1 行に畳むので、序盤の形までは見えない。
35m から始まる長い接近のイベントは、角を指す設計上どうしても序盤が中央寄りになる
(2026-08-20 実測で 7〜12 音ぶん)。その量を測る。
"""
import re
import sys

path = sys.argv[1]
pat = re.compile(r"誘導 角まで=(\d+)m 鳴らす向き=([+-]?\d+)° 音量=([\d.]+)")

events = []
current = None
with open(path, encoding="utf-8") as f:
    for line in f:
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 5:
            continue
        msg = cols[4]
        if msg.startswith("誘導終了"):
            if current:
                events.append(current)
                current = None
            continue
        m = pat.match(msg)
        if not m:
            continue
        t = cols[0][11:19]
        d, rel, gain = int(m.group(1)), int(m.group(2)), float(m.group(3))
        if current is None:
            current = {"start": t, "tones": []}
        current["tones"].append((d, rel, gain))
if current:
    events.append(current)

print(f"{len(events)} イベント。序盤 5 音の 向き(音量):\n")
for i, e in enumerate(events, 1):
    head = "  ".join(f"{r:+4d}°({g:.2f})" for _, r, g in e["tones"][:5])
    lateral = next((k for k, (_, r, _) in enumerate(e["tones"], 1) if abs(r) >= 30), None)
    maxrel = max(abs(r) for _, r, _ in e["tones"])
    print(f"{i:2d}. {e['start']}  {head}")
    print(f"     音 {len(e['tones']):2d} 発 / 最大 {maxrel:3d}° / "
          f"30° を超えたのは {lateral if lateral else '—'} 音目")
