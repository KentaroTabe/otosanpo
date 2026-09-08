#!/usr/bin/env bash
# 使い方: scripts/handoff.sh <案件名> <基準リビジョン>
# 例:     scripts/handoff.sh screenless-test develop
#
# 実装を検証役へ引き渡すための一式を組み立てる(→ docs/16)。
#   入力: codex-exchange/<案件名>-accept.md … 合議で決めた受け入れ条件
#   出力: codex-exchange/<案件名>-check.md  … 検証役へ渡すお題
#
# **実装役の言い分は入れない。** 受け入れ条件と diff だけを渡し、
# 検証役はそれだけを見て判定する(自己申告を検証にしない)。
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-}"
BASE="${2:-}"
if [[ -z "$NAME" || -z "$BASE" ]]; then
  echo "使い方: scripts/handoff.sh <案件名> <基準リビジョン>" >&2
  exit 2
fi

ACCEPT="codex-exchange/${NAME}-accept.md"
OUT="codex-exchange/${NAME}-check.md"
if [[ ! -f "$ACCEPT" ]]; then
  echo "受け入れ条件がありません: $ACCEPT" >&2
  echo "先に合議で受け入れ条件を書き出してください(→ docs/16)" >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "$BASE" > /dev/null; then
  echo "基準リビジョンが見つかりません: $BASE" >&2
  exit 2
fi

{
  echo "あなたはこの案件の **検証役** です(→ \`docs/16_two_agent_workflow.md\`)。"
  echo "実装は別のエージェントが行いました。**実装役の説明は渡しません。**"
  echo "下記の受け入れ条件と差分だけを見て、条件ごとに合否を判定してください。回答は日本語で。"
  echo
  echo "## あなたの仕事"
  echo
  echo "1. **受け入れ条件を 1 つずつ**「満たす / 満たさない / 判定不能」で判定する。"
  echo "   満たさない・判定不能のときは、その根拠となるファイルと行を示す"
  echo "2. **テストが弱められていないか**を見る(\`CLAUDE.md\` の禁止事項)。"
  echo "   アサーションの緩和・skip・期待値の書き換え・テストの削除がないか。"
  echo "   \`Tests/\` の差分は特に注意して読む"
  echo "3. **受け入れ条件に無い変更**が混ざっていないか(案件外のリファクタリング等)"
  echo "4. \`CLAUDE.md\` の規約違反(数値のハードコード・レイヤの依存方向・Core の import)"
  echo "5. **足りないテストを具体的に挙げる**。「テストを増やすべき」ではなく、"
  echo "   入力と期待値を書いた形で挙げる。挙げたものは実装役が走らせて結果を返す"
  echo
  echo "**テストは実行しないでください**(2026-09-08 利用者判断)。"
  echo "サンドボックス内では CoreSimulator が動かず、実行しても環境由来の失敗しか出ません。"
  echo "実行は実装役が行います。**推測で「緑のはず」と書かないでください。**"
  echo
  echo "最後に **合否の結論**(通す / 直してから通す / 設計から見直す)を 1 行で書いてください。"
  echo
  echo "## 受け入れ条件(合議で決めたもの)"
  echo
  cat "$ACCEPT"
  echo
  echo "## 変更されたファイル(${BASE}...HEAD)"
  echo
  echo '```'
  git diff --stat "${BASE}...HEAD"
  echo '```'
  echo
  echo "## 差分"
  echo
  echo '```diff'
  git diff "${BASE}...HEAD"
  echo '```'
} > "$OUT"

LINES=$(wc -l < "$OUT")
echo "検証依頼を書きました: $OUT(${LINES} 行)"
echo "送るには: scripts/ask_codex.sh $OUT --resume"
