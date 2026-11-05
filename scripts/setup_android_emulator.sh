#!/usr/bin/env bash
# 使い方:
#   scripts/setup_android_emulator.sh
#
# Android のエミュレータと AVD を用意する(2026-09-19)。
#
# **手元に Android 実機が無い**(docs/10 の判断待ち 5)。それでも画面の遷移・
# ピッカー・三本線の描画までは確かめられるので、エミュレータを入れる。
# GPS と音の質は確かめられない(そこは実機テスターに頼る)。
#
# 1〜2 GB の取得があるので時間がかかる。2 度目以降は何もしない。
set -euo pipefail
cd "$(dirname "$0")/.."

SDK_ROOT="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
SDKMANAGER="$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$SDK_ROOT/cmdline-tools/latest/bin/avdmanager"
# compileSdk と同じ 35。google_apis 版にするのは、素の版だと機種によって
# 標準のファイルアプリ(ピッカーの受け口)が入っていないため
IMAGE="system-images;android-35;google_apis;arm64-v8a"
AVD_NAME="otosanpo-test"

mkdir -p logs
LOG=logs/setup_android_emulator.log
: > "$LOG"

# **ディスクの空きを先に見る。**
#
# エミュレータは userdata に **7.4 GB(6 GB の 1.2 倍)** の空きを要求する。
# これは**下限で、設定では下げられない**(2026-09-19 実測):
# `disk.dataPartition.size` を 2G・3G にしても、要求は 7372.80 MB のままだった
# (エミュレータ自身が 6 GB へ書き戻す)。`-partition-size` も効かない。
#
# 実際に書かれるのは疎ファイルで数百 MB だが、**起動前の検査で落とされる**ので
# 空きを作る以外に手が無い。
REQUIRED_MB=7373
check_disk() {
  local avail
  avail=$(df -m "$HOME" | awk 'NR == 2 { print $4 }')
  if [ "$avail" -ge "$REQUIRED_MB" ]; then return 0; fi
  echo "ディスクの空きが足りません: ${avail} MB(エミュレータは ${REQUIRED_MB} MB 要求します)" >&2
  echo "約 $(( (REQUIRED_MB - avail) / 1024 + 1 )) GB 空けてから、もう一度実行してください" >&2
  return 1
}

if [ ! -x "$SDKMANAGER" ]; then
  echo "sdkmanager がありません: $SDKMANAGER" >&2
  echo "scripts/setup_android_sdk.sh を先に実行してください" >&2
  exit 1
fi

echo "ライセンスに同意します"
yes | "$SDKMANAGER" --licenses >> "$LOG" 2>&1 || true

echo "emulator と $IMAGE を入れます(1〜2 GB・数分かかります)"
if ! "$SDKMANAGER" --install "emulator" "$IMAGE" >> "$LOG" 2>&1; then
  tail -n 30 "$LOG"
  echo "エミュレータの取得に失敗しました" >&2
  exit 1
fi

if "$AVDMANAGER" list avd --compact 2>> "$LOG" | grep -qx "$AVD_NAME"; then
  echo "AVD はすでにあります: $AVD_NAME"
  check_disk || true
  exit 0
fi

echo "AVD を作ります: $AVD_NAME"
if ! echo "no" | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$IMAGE" -d "pixel_6" \
    >> "$LOG" 2>&1; then
  tail -n 30 "$LOG"
  echo "AVD を作れませんでした" >&2
  exit 1
fi
check_disk || true

echo "用意できました。scripts/run_android_emulator.sh で起動します"
