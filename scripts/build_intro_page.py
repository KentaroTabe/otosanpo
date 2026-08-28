"""紹介ページ(Artifact 用の HTML)を組み立てる。

使い方: scripts/build_intro_page.py [音のディレクトリ] [出力 HTML]

音は data: URI で埋め込む。Artifact は外部ホストへの取得を CSP で塞ぐため、
外に置いた音声ファイルは鳴らない。テンプレートの雛形へ WAV を base64 で流し込む。

座標・地図・経路は扱わない(入力は WAV と、鳴った音の時刻・左右・音量だけ)。
"""
import base64
import json
import sys
from pathlib import Path

audio_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "build-demo")
out_path = Path(sys.argv[2] if len(sys.argv) > 2 else "build-demo/intro.html")
template = Path("scripts/intro_page.html").read_text(encoding="utf-8")


def data_uri(name: str) -> str:
    raw = (audio_dir / name).read_bytes()
    return "data:audio/wav;base64," + base64.b64encode(raw).decode("ascii")


placeholders = {
    "__SCENE_WANDERING__": "scene-wandering.wav",
    "__SCENE_RETURN_FAR__": "scene-return-far.wav",
    "__SCENE_RETURN_NEAR__": "scene-return-near.wav",
    "__TONE_SUGGESTION__": "suggestion.wav",
    "__TONE_TIME_UP__": "time-up.wav",
    "__TONE_RETURN_ACK__": "return-ack.wav",
    "__TONE_HOME_BEACON__": "home-beacon.wav",
    "__TONE_ARRIVAL__": "arrival.wav",
}

html = template
for key, name in placeholders.items():
    html = html.replace(key, data_uri(name))

scenes = json.loads((audio_dir / "scenes.json").read_text(encoding="utf-8"))
html = html.replace("__SCENES_JSON__", json.dumps(scenes, separators=(",", ":")))

out_path.parent.mkdir(parents=True, exist_ok=True)
out_path.write_text(html, encoding="utf-8")
size = out_path.stat().st_size / 1_000_000
print(f"{out_path}: {size:.1f} MB")
if size > 15:
    print("警告: Artifact の上限(16 MB)に近い。音を短くするか標本化周波数を下げること")
