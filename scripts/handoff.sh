#!/usr/bin/env bash
# 使い方: scripts/handoff.sh <案件名> <base の SHA> <candidate の SHA>
# 例:     scripts/handoff.sh screenless-test develop HEAD
#
# 実装を検証役へ引き渡すための一式を組み立てる(→ docs/16)。
#   入力: codex-exchange/<案件名>-accept.md    … 合議で決めた受け入れ条件
#         codex-exchange/<案件名>-evidence.md  … テストの実行結果(あれば。実装役が書く)
#   出力: codex-exchange/<案件名>-check.md     … 検証役へ渡すお題
#
# **実装役の言い分は入れない。** 受け入れ条件と差分だけを渡し、
# 検証役はそれだけを物差しにする(自己申告を検証にしない)。
#
# **SHA を固定する。** HEAD のまま渡すと、検証している間に HEAD が動いて
# 「何を検証したのか」が曖昧になる。未コミットの変更があれば止まる。
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:-}"
BASE_REF="${2:-}"
CAND_REF="${3:-}"
if [[ -z "$NAME" || -z "$BASE_REF" || -z "$CAND_REF" ]]; then
  echo "使い方: scripts/handoff.sh <案件名> <base の SHA> <candidate の SHA>" >&2
  exit 2
fi

ACCEPT="codex-exchange/${NAME}-accept.md"
EVIDENCE="codex-exchange/${NAME}-evidence.md"
OUT="codex-exchange/${NAME}-check.md"
if [[ ! -f "$ACCEPT" ]]; then
  echo "受け入れ条件がありません: $ACCEPT" >&2
  echo "先に合議で受け入れ条件を書き出してください(→ docs/16)" >&2
  exit 2
fi

BASE=$(git rev-parse --verify --quiet "$BASE_REF" || true)
CAND=$(git rev-parse --verify --quiet "$CAND_REF" || true)
if [[ -z "$BASE" || -z "$CAND" ]]; then
  echo "リビジョンを解決できません(base=$BASE_REF candidate=$CAND_REF)" >&2
  exit 2
fi

# 検証対象を固定するため、追跡下の未コミット変更があれば止める
if ! git diff --quiet HEAD --; then
  echo "未コミットの変更があります。検証する版が定まらないのでコミットしてください:" >&2
  git status --short >&2
  exit 2
fi

{
  echo "あなたはこの案件の **検証役** です(→ \`docs/16_two_agent_workflow.md\`)。"
  echo "実装は別のエージェントが行いました。**実装役の説明は渡しません。**"
  echo "下記の受け入れ条件と差分を物差しにして、条件ごとに合否を判定してください。回答は日本語で。"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| 案件 | ${NAME} |"
  echo "| 受け入れ条件 | ${ACCEPT} |"
  echo "| base | \`${BASE}\` |"
  echo "| candidate | \`${CAND}\` |"
  echo
  echo "差分だけを読むのではなく、**リポジトリ本体を自由に読んでください**"
  echo "(変更行の周辺・呼び出し元・既存テスト・設定・文書)。"
  echo "相互作用の欠陥は変更行だけでは見つかりません。渡さないのは実装役の自己説明だけです。"
  echo
  echo "## あなたの仕事"
  echo
  echo "1. **受け入れ条件を 1 つずつ**「満たす / 満たさない / 判定不能」で判定する。"
  echo "   満たさない・判定不能のときは、根拠となるファイルと行を示す"
  echo "2. **テストが弱められていないか**を見る(\`CLAUDE.md\` の禁止事項)。"
  echo "   アサーションの緩和・skip・期待値の書き換え・テストの削除がないか。"
  echo "   \`Tests/\` の差分は特に注意して読む"
  echo "3. **受け入れ条件に無い変更**が混ざっていないか(案件外のリファクタリング等)"
  echo "4. \`CLAUDE.md\` の規約違反(数値のハードコード・レイヤの依存方向・Core の import)"
  echo "5. **足りないテストを具体的に挙げる**。「テストを増やすべき」ではなく、"
  echo "   入力と期待値を書いた形で挙げる。挙げたものは実装役が書いて走らせ、結果を返す"
  echo
  echo "**テストは実行しないでください**(2026-09-08 利用者判断)。"
  echo "サンドボックス内では CoreSimulator が動かず、実行しても環境由来の失敗しか出ません。"
  echo "実行は実装役が行います。**推測で「緑のはず」と書かないでください。**"
  echo
  echo "最後に **合否の結論**を 1 行で書いてください:"
  echo "「実機投入可」/「直してから実機投入」/「設計から見直す」。"
  echo
  echo "## 受け入れ条件(合議で決めたもの)"
  echo
  cat "$ACCEPT"
  echo
  if [[ -f "$EVIDENCE" ]]; then
    echo "## テストの実行結果(機械的な記録)"
    echo
    cat "$EVIDENCE"
    echo
  fi
  echo "## 変更されたファイル(${BASE_REF} → ${CAND_REF})"
  echo
  echo '```'
  git diff --stat "${BASE}..${CAND}"
  echo '```'
  echo
  echo "## 差分"
  echo
  echo '```diff'
  git diff "${BASE}..${CAND}"
  echo '```'
} > "$OUT"

LINES=$(wc -l < "$OUT")
echo "検証依頼を書きました: $OUT(${LINES} 行)"
echo "  base=${BASE} candidate=${CAND}"
echo "送るには: scripts/ask_codex.sh $OUT --resume"
