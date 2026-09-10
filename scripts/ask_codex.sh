#!/usr/bin/env bash
# 使い方: scripts/ask_codex.sh <お題ファイル> [--resume] [--write]
# 例:     scripts/ask_codex.sh codex-exchange/01-design.md
#         scripts/ask_codex.sh codex-exchange/02-design.md --resume
#         scripts/ask_codex.sh codex-exchange/05-check.md --resume
#
# お題ファイルの中身を Codex へ渡し、返答を <お題ファイル>.reply.md に書く。
# --resume  このリポジトリで最後に開いた会話の続きにする(付けなければ新しい会話)
# --write   ワークスペースへの書き込みを許す。**検証では使わない**(検証役はテストを
#           実行しない・docs/16)。相手に実装させる案件で使う
#
# 生ログは codex-exchange/ 配下(gitignore 対象)。決まったことは docs/ へ書き写す。
set -euo pipefail
cd "$(dirname "$0")/.."

PROMPT_FILE="${1:-}"
if [[ -z "$PROMPT_FILE" ]]; then
  echo "お題ファイルを指定してください: scripts/ask_codex.sh <ファイル> [--resume] [--write]" >&2
  exit 2
fi
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "お題ファイルがありません: $PROMPT_FILE" >&2
  exit 2
fi
shift

RESUME=no
SANDBOX=read-only
for arg in "$@"; do
  case "$arg" in
    --resume) RESUME=yes ;;
    --write)  SANDBOX=workspace-write ;;
    *) echo "知らない引数: $arg" >&2; exit 2 ;;
  esac
done

# Codex の在処。PATH に無ければ ChatGPT.app 同梱のものを使う
CODEX="$(command -v codex || true)"
if [[ -z "$CODEX" ]]; then
  CODEX="/Applications/ChatGPT.app/Contents/Resources/codex"
fi
if [[ ! -x "$CODEX" ]]; then
  echo "codex が見つかりません($CODEX)" >&2
  exit 1
fi

REPLY_FILE="${PROMPT_FILE%.md}.reply.md"
RAW_LOG="${PROMPT_FILE%.md}.raw.log"
rm -f "$REPLY_FILE"

echo "Codex へ送ります: $PROMPT_FILE (resume=$RESUME sandbox=$SANDBOX)"
START=$(date +%s)

set +e
if [[ "$RESUME" == "yes" ]]; then
  # resume は -s も --color も受け付けない。設定の上書きでサンドボックスを指定する
  "$CODEX" exec resume --last --skip-git-repo-check \
    -c sandbox_mode="$SANDBOX" \
    -o "$REPLY_FILE" "$(cat "$PROMPT_FILE")" > "$RAW_LOG" 2>&1
else
  "$CODEX" exec --skip-git-repo-check --color never -s "$SANDBOX" \
    -o "$REPLY_FILE" "$(cat "$PROMPT_FILE")" > "$RAW_LOG" 2>&1
fi
STATUS=$?
set -e

ELAPSED=$(( $(date +%s) - START ))

if [[ ! -s "$REPLY_FILE" ]]; then
  echo "返答が空です(終了コード $STATUS・${ELAPSED} 秒)。生ログの末尾:" >&2
  tail -n 40 "$RAW_LOG" >&2
  exit 1
fi

echo "返答を書きました: $REPLY_FILE(${ELAPSED} 秒・終了コード $STATUS)"
