#!/usr/bin/env bash
# 使い方:
#   scripts/replay_log.sh                            field-logs/ の最新ログを再生する
#   scripts/replay_log.sh <ファイル>                 指定したログを再生する
#   scripts/replay_log.sh <ファイル> <設定>          閾値を振り直して比べる
#     (設定 JSON を書き換えた版を渡す。歩き直さずに値を決めるための道具)
#   scripts/replay_log.sh <ファイル> <設定> <地図>   地図を指定して再生する
#
# **地図を指定できるようにしたのは、テスターの散歩を再生するため**(2026-10-03)。
# 既定の `maps/otosanpo-map.json` は開発者の自宅周辺なので、
# 他の土地のログでは経路の場が作れず、「経路データがないので判定できません」で終わる。
#   例: scripts/replay_log.sh field-logs/<名古屋のログ>.tsv \
#         config/parameters.json maps/set/名古屋市.json
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

CONFIG="${2:-config/parameters.json}"
if [ ! -f "$CONFIG" ]; then
  echo "設定ファイルがありません: $CONFIG" >&2
  exit 1
fi

MAP="${3:-maps/otosanpo-map.json}"
if [ ! -f "$MAP" ]; then
  echo "地図がありません: $MAP" >&2
  exit 1
fi

# **自宅(任意)。** 渡さないと到着地点で近似するが、ログが自宅の手前で終わっていると
# 目標がずれ、ビーコンの節が実機を再現しない(2026-10-03)。
# ログの「自宅を現在地に設定しました」の行から座標を読んで渡す
HOME_POINT="${4:-}"

if [ -n "$HOME_POINT" ]; then
  "$BIN" "$SRC" "$CONFIG" "$MAP" "$HOME_POINT"
else
  "$BIN" "$SRC" "$CONFIG" "$MAP"
fi
