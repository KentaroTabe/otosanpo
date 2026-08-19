#!/usr/bin/env bash
# 使い方: scripts/setup_labels.sh
#
# Issue テンプレート(.github/ISSUE_TEMPLATE/)が指定しているラベルを作る。
# **GitHub は存在しないラベルを黙って捨てる**ため、これを実行しないと
# テンプレートで付けたつもりのラベルが付かない。
#
# 何度実行してもよい(--force で既存のラベルは色と説明を更新する)。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
echo "対象: $REPO"

# 色は面ごとに分ける(一覧で見たときに種類が分かるように)
create() {
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force > /dev/null
  echo "  $1"
}

echo "不具合の面(どの subsystem か)"
create audio    "1d76db" "音の鳴り方・定位・音量"
create guidance "0e8a16" "提案・曲がり角の誘導・行き先の選び方"
create budget   "fbca04" "帰宅時間の見積もり・延長・到着判定"
create gesture  "d4c5f9" "うなずき・首振りの検出"
create location "5319e7" "位置精度・進行方向・道路スナップ"
create app      "c2e0c6" "バックグラウンド動作・権限・クラッシュ・UI"

echo "作業の種類"
create task       "bfd4f2" "実装・リファクタリング・調査"
create field-test "e99695" "実機で歩いた回の記録"

echo "完了。既存の bug / enhancement はそのまま使う。"
