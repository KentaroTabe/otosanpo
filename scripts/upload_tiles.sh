#!/usr/bin/env bash
# 使い方: scripts/upload_tiles.sh <R2バケット名> [rcloneリモート名]
#   例:   scripts/upload_tiles.sh otosanpo
#
# maps/tiles/ の中身(タイルと meta.json)を Cloudflare R2 へ上げる。
#
# **このスクリプトは人が実行する。** 認証情報が要り、外向きの操作だから
# (CLAUDE.md / docs/12)。開発の流れから自動では呼ばれない。
#
# ## 事前(1 回だけ)
#
# 1. Cloudflare のダッシュボードで **R2 API トークン**を作る
#    - 権限は **Object Read & Write**。**読みも要る**(rclone は差分を見るため
#      HeadObject する。書き込みだけのトークンでは 403 で止まる)
#    - 対象バケットを間違えないこと
# 2. rclone に登録する(対話式。**鍵はここでしか扱わない**)
#
#      rclone config create r2 s3 provider=Cloudflare region=auto \
#        endpoint=https://<アカウントID>.r2.cloudflarestorage.com
#      rclone config update r2 access_key_id=<...> secret_access_key=<...>
#
# 3. 疎通を確認する(これが通らなければ転送は始めない)
#
#      rclone lsf r2:<バケット名>
#
# 4. バケットの**公開アクセスを有効にする**(アプリは認証を持たない)
#
# ## なぜ wrangler をやめたか(2026-08-29)
#
# 以前は `npx wrangler r2 object put` を 1 ファイルずつ呼んでいた。2 つ問題があった:
#
# - **npx が wrangler のインストール確認を対話で聞き、出力をログへ流していたため
#   答えられず、12 時間 1 件目で止まった**(実際に起きた)
# - 直しても **1 ファイルごとに Node を起動する**ので、17,000 件で数時間〜十数時間かかる
#
# rclone は S3 API を直に叩き、**並列**で送り、**中断しても差分だけ**送り直せる。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "使い方: scripts/upload_tiles.sh <R2バケット名> [rcloneリモート名]" >&2
  exit 1
fi
BUCKET="$1"
REMOTE="${2:-r2}"

if ! command -v rclone > /dev/null; then
  echo "rclone がありません: brew install rclone" >&2
  exit 1
fi
if [ ! -f maps/tiles/meta.json ]; then
  echo "maps/tiles/meta.json がありません。先に scripts/build_tiles.sh を実行してください" >&2
  exit 1
fi

# **転送を始める前に権限を確かめる。** ここで落ちれば数 GB を無駄に送らずに済む。
# 一晩を溶かした原因は「始まってすらいないのに気づけなかった」ことなので、
# 疎通の確認を必須の前段に置く
echo "疎通を確認: ${REMOTE}:${BUCKET}"
if ! rclone lsf "${REMOTE}:${BUCKET}" --max-depth 1 > /dev/null 2>&1; then
  echo >&2
  echo "${REMOTE}:${BUCKET} を読めません(権限かバケット名の問題)。" >&2
  echo "  - R2 API トークンの権限が **Object Read & Write** か" >&2
  echo "  - そのトークンの対象バケットが ${BUCKET} か" >&2
  echo "  - rclone の endpoint のアカウント ID が合っているか" >&2
  echo "詳しくは rclone lsf ${REMOTE}:${BUCKET} を直接実行してエラーを見てください" >&2
  exit 1
fi

COUNT=$(ls maps/tiles | wc -l | tr -d ' ')
echo "転送: ${COUNT} ファイル / $(du -sh maps/tiles | cut -f1)"

# --transfers: 並列数。R2 の Class A 操作は無料枠 100 万/月なので 17,000 件は問題ない
# --checksum: 中断後の再実行で、送り直す分だけを選ぶ
rclone copy maps/tiles "${REMOTE}:${BUCKET}" \
  --transfers 32 --checkers 32 --checksum --progress

echo
echo "完了しました。アプリ側の確認:"
echo "  curl -sI <公開URL>/meta.json"
echo "config/parameters.json の map_download.base_url に公開 URL を入れる"
