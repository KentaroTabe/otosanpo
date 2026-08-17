#!/usr/bin/env bash
# 使い方:
#   scripts/replay_log.sh              field-logs/ の最新ログを再生する
#   scripts/replay_log.sh <ファイル>   指定したログを再生する
#
# 記録したフィールドログを Core の純粋ロジックに流し直し、経路長・迂回率・
# フィルタの寄与を計算する。実機で歩き直さずに実装の正しさを確かめるための道具。
#
# 前提: ログに fix 行(位置更新 1 件ごとの記録)が入っていること。
# 2026-08-17 以降のビルドから記録される。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p logs
LOG=logs/replay_build.log
BIN=build-replay/Build/Products/Debug/otosanpo-replay

if ! xcodebuild -project OtoSanpo.xcodeproj -scheme Replay \
    -destination 'platform=macOS' -derivedDataPath build-replay build > "$LOG" 2>&1; then
  tail -n 40 "$LOG"
  echo "再生ツールのビルドに失敗しました" >&2
  exit 1
fi

if [ $# -ge 1 ]; then
  SRC="$1"
else
  SRC=$(ls -t field-logs/*.tsv 2>/dev/null | head -n 1 || true)
fi

if [ -z "${SRC:-}" ] || [ ! -f "$SRC" ]; then
  echo "ログが見つかりません。先に scripts/import_log.sh で取り込んでください。" >&2
  exit 1
fi

"$BIN" "$SRC" config/parameters.json
