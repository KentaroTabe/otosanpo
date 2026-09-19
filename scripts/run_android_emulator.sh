#!/usr/bin/env bash
# 使い方:
#   scripts/run_android_emulator.sh              起動して APK を入れ、アプリを開く
#   scripts/run_android_emulator.sh stop         止める
#   scripts/run_android_emulator.sh shot <名前>   画面を撮って dist/shots/<名前>.png へ
#
# エミュレータで画面を確かめる(2026-09-19)。
#
# **確かめられるのは画面の遷移だけ。** GPS の質・音の左右・歩調は実機でしか分からない
# (docs/10)。それでも、三本線が描けているか・ピッカーが開くか・落ちないかは見える。
#
# 事前に scripts/setup_android_emulator.sh を 1 回実行しておくこと。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_ROOT="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
EMULATOR="$SDK_ROOT/emulator/emulator"
ADB="$SDK_ROOT/platform-tools/adb"
AVD_NAME="otosanpo-test"
APK=dist/otosanpo-android.apk
PACKAGE=dev.otosanpo

MODE="${1:-run}"

mkdir -p logs dist/shots
LOG=logs/run_android_emulator.log

case "$MODE" in
  stop)
    "$ADB" emu kill 2>/dev/null || true
    echo "止めました"
    exit 0
    ;;
  shot)
    NAME="${2:-screen}"
    OUT="dist/shots/${NAME}.png"
    "$ADB" exec-out screencap -p > "$OUT"
    echo "$OUT"
    exit 0
    ;;
esac

if [ ! -x "$EMULATOR" ]; then
  echo "エミュレータがありません。scripts/setup_android_emulator.sh を先に実行してください" >&2
  exit 1
fi

if ! "$ADB" devices | grep -q "emulator-"; then
  # **空きが足りなければ起動前に止める。** エミュレータは 7.4 GB を要求し、
  # 設定では下げられない(→ setup_android_emulator.sh の check_disk)
  AVAIL_MB=$(df -m "$HOME" | awk 'NR == 2 { print $4 }')
  if [ "$AVAIL_MB" -lt 7373 ]; then
    echo "ディスクの空きが足りません: ${AVAIL_MB} MB(7373 MB 要ります)" >&2
    echo "約 $(( (7373 - AVAIL_MB) / 1024 + 1 )) GB 空けてから、もう一度実行してください" >&2
    exit 1
  fi
  echo "エミュレータを起動します: $AVD_NAME"
  # **画面は出さない。** 撮るのは adb 越しなので窓は要らず、窓を開くと
  # 他の作業の前に割り込む。音は鳴らせないが、鳴らすのは実機の仕事
  # **GPU はソフトウェア描画(swiftshader)にする。**
  #
  # 2026-09-19 に両方試した結果:
  #
  # | 設定 | 画面を撮れるか | SystemUI |
  # |---|---|---|
  # | `-gpu auto`(Mac では Metal) | **真っ黒**。窓なしでは面を読めない | 軽い |
  # | `-gpu swiftshader_indirect` | **撮れる** | 重い(ANR が出る) |
  #
  # **撮れないと確かめる意味が無い**のでソフトウェア描画を採り、
  # 代わりにアニメーションを切って SystemUI の負荷を下げる(下記)
  "$EMULATOR" -avd "$AVD_NAME" -no-window -no-audio -no-snapshot \
      -gpu swiftshader_indirect -no-boot-anim >> "$LOG" 2>&1 &
fi

echo "起動を待ちます(初回は数分かかります)"
"$ADB" wait-for-device
for _ in $(seq 1 180); do
  if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
    break
  fi
  sleep 2
done
if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]; then
  echo "起動しませんでした。logs/run_android_emulator.log を見てください" >&2
  exit 1
fi

if [ ! -f "$APK" ]; then
  echo "APK がありません: $APK" >&2
  echo "scripts/build_android.sh で作ってください" >&2
  exit 1
fi

# **アニメーションを切る。** ソフトウェア描画では SystemUI が追いつかず、
# 「System UI isn't responding」が画面を覆って確かめられなくなる(2026-09-19 実測)
for KEY in window_animation_scale transition_animation_scale animator_duration_scale; do
  "$ADB" shell settings put global "$KEY" 0 >> "$LOG" 2>&1 || true
done

echo "APK を入れます"
"$ADB" install -r "$APK" >> "$LOG" 2>&1

# **許可はあらかじめ与える。** ダイアログを潰すのが目的ではないので、
# 見たい画面まで最短で行く(許可の流れ自体を見る時は revoke してから開く)
for PERM in android.permission.ACCESS_FINE_LOCATION \
            android.permission.ACTIVITY_RECOGNITION \
            android.permission.POST_NOTIFICATIONS; do
  "$ADB" shell pm grant "$PACKAGE" "$PERM" >> "$LOG" 2>&1 || true
done

"$ADB" shell am start -n "$PACKAGE/.MainActivity" >> "$LOG" 2>&1
echo "開きました。scripts/run_android_emulator.sh shot <名前> で画面を撮れます"
