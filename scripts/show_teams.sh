#!/usr/bin/env bash
# 使い方: scripts/show_teams.sh
# 手元の署名証明書から Team ID(証明書の OU)を取り出して表示する。
# 証明書名の括弧内は Team ID とは限らないため、OU を正解として扱う。
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

security find-certificate -a -c "Apple Development" -p > "$WORK/all.pem" 2>/dev/null || true
security find-certificate -a -c "iPhone Developer" -p >> "$WORK/all.pem" 2>/dev/null || true

if [ ! -s "$WORK/all.pem" ]; then
  echo "開発用証明書が見つかりません。"
  echo "Xcode > Settings > Accounts > Manage Certificates > + > Apple Development で作成してください。"
  exit 0
fi

awk -v dir="$WORK" 'BEGIN { n = 0 }
  /-----BEGIN CERTIFICATE-----/ { n++ }
  n > 0 { print > (dir "/cert" n ".pem") }' "$WORK/all.pem"

for f in "$WORK"/cert*.pem; do
  [ -e "$f" ] || continue
  subject=$(openssl x509 -in "$f" -noout -subject -nameopt sep_multiline 2>/dev/null || true)
  cn=$(printf '%s\n' "$subject" | sed -n 's/^ *CN=//p')
  ou=$(printf '%s\n' "$subject" | sed -n 's/^ *OU=//p')
  [ -n "$ou" ] || continue
  echo "証明書: $cn"
  echo "  Team ID (OU): $ou"
done

echo
echo "上記の Team ID を設定するには: scripts/set_team.sh <TEAM_ID>"
