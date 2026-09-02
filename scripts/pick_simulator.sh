#!/usr/bin/env bash
# 使い方: scripts/pick_simulator.sh
#
# 使える iPhone のシミュレータ名を 1 つ選んで表示する。
#
# **なぜ要るか**: シミュレータ名は Xcode の版で変わる(手元は iPhone 17 Pro、
# CI のランナーは別の版)。名前を固定すると、Xcode が上がった日に
# 「実装は正しいのに CI だけ赤」になる。**それは CI の信頼を壊す**ので、
# 存在するものから選ぶ。
#
# 選び方は「iPhone の中で数字がいちばん大きいもの」= その Xcode で最も新しい機種。
# 同点なら無印 < Pro < Pro Max の順で、無印を優先する(素の構成で通ることを見たい)。
set -euo pipefail

LIST=$(xcrun simctl list devices available)

# 「    iPhone 16 Pro (UUID) (Shutdown)」から機種名だけ取り出す
NAME=$(printf '%s\n' "$LIST" \
  | sed -n 's/^ *\(iPhone [^(]*\) (.*/\1/p' \
  | sed 's/ *$//' \
  | awk '{
      n = $2 + 0
      # 無印を優先するため、語数が少ないほど小さい副キーにする
      print n "\t" NF "\t" $0
    }' \
  | sort -k1,1nr -k2,2n -k3,3 \
  | head -n 1 \
  | cut -f3-)
# 3 つ目の鍵(名前の昇順)まで入れて**同点の解決を決定的にする**。
# 無いと「iPhone 17」と「iPhone 17e」のような同点で実行ごとに選択が変わり、
# CI の再現性が失われる

if [ -z "$NAME" ]; then
  echo "使える iPhone のシミュレータがありません。" >&2
  echo "Xcode > Settings > Platforms から iOS のシミュレータを入れてください。" >&2
  printf '%s\n' "$LIST" >&2
  exit 1
fi

echo "$NAME"
