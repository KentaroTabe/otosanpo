#!/usr/bin/env bash
# 使い方: scripts/experiment.sh on | off | status
#
# 実験ビルド(頭部固定)のスイッチを切り替える。**スイッチは head_mount.enabled ただ 1 つ**で、
# 頭部固定・有効性パルス・実験用の音色がまとめて入る(→ docs/13)。
#
#   on      実験を有効にする。この状態で Xcode からビルドして実機に入れる
#   off     配布と同じ状態に戻す。**ビルドが済んだら必ず戻す**
#   status  いまどちらか
#
# **この変更はコミットしない。** on の間は検査 1 件が意図的に落ちる(それが番人)。
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-status}"
CONFIG=config/parameters.json

case "$ACTION" in
  on|off|status) ;;
  *) echo "使い方: scripts/experiment.sh on | off | status" >&2; exit 2 ;;
esac

# 事故防止: parameters.json が既にステージされていると、実験の値を巻き込んで
# コミットしうる。**判断待ちの音を配布物へ焼き込んだ前科がある**(2026-09-02)
if [ "$ACTION" != "status" ]; then
  if ! git diff --cached --quiet -- "$CONFIG"; then
    echo "$CONFIG がステージされています。実験のスイッチを巻き込む恐れがあるので中止します。" >&2
    echo "  git restore --staged $CONFIG  で外してからやり直してください。" >&2
    exit 1
  fi
fi

BEFORE=$(python3 scripts/set_experiment.py "$CONFIG" status)
NOW=$(python3 scripts/set_experiment.py "$CONFIG" "$ACTION")

if [ "$ACTION" = "status" ]; then
  echo "実験のスイッチ(head_mount.enabled): $NOW"
  if [ "$NOW" = "on" ]; then
    echo "  → 実験ビルドの状態です。配布用にするには scripts/experiment.sh off"
  fi
  exit 0
fi

if [ "$BEFORE" = "$NOW" ]; then
  echo "すでに $NOW でした(変更なし)"
else
  echo "実験のスイッチ: $BEFORE → $NOW"
fi

if [ "$NOW" = "off" ]; then
  echo "配布と同じ状態です。テストは全緑に戻ります。"
  exit 0
fi

# on のときだけ、何が入るのかを読み上げる。
# **「入れ忘れ」ではなく「入っていることの確認」がここの目的**
PULSE=$(scripts/read_param.sh experiment.validity_pulse_sec)
GAIN=$(scripts/read_param.sh experiment.validity_pulse_gain)
HARM=$(scripts/read_param.sh experiment.directional_harmonics)
ATTACK=$(scripts/read_param.sh experiment.directional_attack_ratio)
STALE=$(scripts/read_param.sh head_mount.stale_sec)

cat <<'HEADER'

このビルドに入るもの:
HEADER
echo "  1. 頭部固定の絶対方位を定位の基準にする(学習が立ち・検疫を通り・標本が新鮮な間だけ)"
echo "     鮮度の上限 ${STALE} 秒。更新が止まれば進行方位へ退避する"
echo "  2. 有効性パルス: ${PULSE} 秒おき・音量 ${GAIN}・中央で鳴る"
echo "     → 「いま試してよい」の唯一の合図。鳴らない = 試さない"
echo "  3. 実験用の音色(方向を担う 2 種のみ): 倍音 ${HARM}・アタック ${ATTACK}"
echo "     → 時間到来・確認音・到着は配布版のまま"
echo "  4. 立ち止まっても左右が消えない(ビーコン・曲がり角の誘導とも)"
echo "  5. ログ: 頭方位(生 heading 付き)・使用可能状態の遷移・定位の基準・パルスの記録"
cat <<'FOOTER'

散歩の前に:
  - scripts/build_demo.sh を実行し、build-demo/ab-beacon.wav をイヤホンで聴く
    後半 4 音で左右がはっきり分かれないなら、散歩に出ない(docs/05)
  - 端末に地図が入っていること(画面に「地図: 半径5km・<生成日>」)

**この変更はコミットしないでください。**
  - 検査 testTheExperimentSwitchIsOffInTheShippedConfig が意図的に落ちます。
    それが「実験の値を配布物へ混ぜない」番人なので、通そうとしないこと
  - ビルドが済んだら scripts/experiment.sh off で戻す

ビルドは Xcode から行ってください(実機への導入は人の手で)。
FOOTER
