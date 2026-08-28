"""アプリアイコン(1024x1024 PNG)を作る。

**仮のアイコンである。** App Store Connect はアイコンの無いビルドを受け付けないので、
TestFlight へ上げるために置いている。デザインが決まったら差し替える。

図柄: 1 点から右へ広がる弧。「音の鳴る方へ歩く」という中身をそのまま絵にしたもの。

使い方: scripts/make_icon.py [出力先]
外部ライブラリを使わない(zlib と struct だけで PNG を書く)。
"""
import math
import struct
import sys
import zlib
from pathlib import Path

SIZE = 1024
BG = (0x1B, 0x24, 0x30)      # 夜の紺
FG = (0xF2, 0xC1, 0x4E)      # 音の色(琥珀)

# 音源の点と、そこから右へ広がる 3 本の弧
SOURCE = (SIZE * 0.34, SIZE * 0.5)
DOT_R = SIZE * 0.055
ARCS = [SIZE * 0.17, SIZE * 0.29, SIZE * 0.41]
ARC_W = SIZE * 0.042
ARC_SPAN_DEG = 52.0


def build() -> bytearray:
    px = bytearray()
    for y in range(SIZE):
        px.append(0)  # フィルタ種別 0(なし)
        for x in range(SIZE):
            dx = x - SOURCE[0]
            dy = y - SOURCE[1]
            d = math.hypot(dx, dy)
            color = BG
            if d <= DOT_R:
                color = FG
            else:
                # 右向き ±ARC_SPAN_DEG の扇の中だけ弧を描く
                angle = math.degrees(math.atan2(dy, dx))
                if abs(angle) <= ARC_SPAN_DEG:
                    for r in ARCS:
                        if abs(d - r) <= ARC_W / 2:
                            color = FG
                            break
            px.extend(color)
    return px


def chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1
               else "Support/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
    out.parent.mkdir(parents=True, exist_ok=True)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8bit RGB
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", header)
           + chunk(b"IDAT", zlib.compress(bytes(build()), 9))
           + chunk(b"IEND", b""))
    out.write_bytes(png)
    print(f"{out}: {len(png) / 1000:.0f} KB")


main()
