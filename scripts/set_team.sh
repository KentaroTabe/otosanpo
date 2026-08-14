#!/usr/bin/env bash
# 使い方:
#   scripts/set_team.sh            現在の設定と、利用可能な署名 ID を表示する
#   scripts/set_team.sh <TEAM_ID>  Support/Signing.xcconfig に Team ID を書き込む
# Team ID は Xcode > Settings > Accounts の Team 欄、または下記一覧の括弧内で確認できる。
set -euo pipefail
cd "$(dirname "$0")/.."

CONF=Support/Signing.xcconfig

if [ ! -f "$CONF" ]; then
  cp Support/Signing.example.xcconfig "$CONF"
  echo "$CONF を作成しました。"
fi

TEAMS_PLIST="$HOME/Library/Developer/Xcode/UserData/IDEProvisioningTeams.plist"

if [ $# -eq 0 ]; then
  echo "--- 現在の設定 ($CONF) ---"
  grep -E '^DEVELOPMENT_TEAM' "$CONF" || echo "DEVELOPMENT_TEAM の行がありません"

  echo
  echo "--- Xcode に登録済みの Team ---"
  if [ -f "$TEAMS_PLIST" ]; then
    plutil -p "$TEAMS_PLIST" | grep -E '"(teamID|teamName|teamType)"' || echo "Team の記載がありません"
  else
    echo "未登録($TEAMS_PLIST がありません)"
    echo "Xcode > Settings > Accounts で Apple ID を追加してください。"
  fi

  echo
  echo "--- 署名証明書 ---"
  security find-identity -v -p codesigning || true
  echo "(0 件の場合、Xcode > Settings > Accounts > Manage Certificates > + > Apple Development で作成)"
  echo "※ 証明書名の括弧内は開発者 ID であり Team ID ではない。Team ID は 'scripts/show_teams.sh' で確認する"

  echo
  echo "設定するには: scripts/set_team.sh <TEAM_ID>"
  exit 0
fi

TEAM="$1"
if ! printf '%s' "$TEAM" | grep -qE '^[A-Z0-9]{10}$'; then
  echo "Team ID は英数字 10 桁です(入力: $TEAM)" >&2
  exit 1
fi

TMP=$(mktemp)
if grep -qE '^DEVELOPMENT_TEAM[[:space:]]*=' "$CONF"; then
  # '=' の直後に空白が無い場合もあるため、行頭キーだけで照合する
  sed -E "s/^DEVELOPMENT_TEAM[[:space:]]*=.*/DEVELOPMENT_TEAM = ${TEAM}/" "$CONF" > "$TMP"
else
  cp "$CONF" "$TMP"
  echo "DEVELOPMENT_TEAM = ${TEAM}" >> "$TMP"
fi
mv "$TMP" "$CONF"

# 書き換わったことを確認してから成功を報告する(黙って失敗させない)
if ! grep -qE "^DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*${TEAM}$" "$CONF"; then
  echo "書き込みに失敗しました。$CONF を直接確認してください。" >&2
  exit 1
fi
grep -E '^DEVELOPMENT_TEAM' "$CONF"
echo "設定しました。'scripts/setup.sh' で再生成してから実機ビルドしてください。"
