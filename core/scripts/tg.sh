#!/usr/bin/env bash
# Send a Telegram message. Used for loop notifications and escalations.
# Usage: tg.sh "message text" [parse_mode]
# parse_mode defaults to Markdown.
set -euo pipefail

MSG="${1:-}"
PARSE_MODE="${2:-Markdown}"

[ -z "$MSG" ] && exit 0
[ -z "${KIRO_TG_BOT_TOKEN:-}" ] && exit 0
[ -z "${KIRO_TG_CHAT_ID:-}" ] && exit 0

curl -s -X POST "https://api.telegram.org/bot${KIRO_TG_BOT_TOKEN}/sendMessage" \
  -d chat_id="$KIRO_TG_CHAT_ID" \
  -d text="$MSG" \
  -d parse_mode="$PARSE_MODE" > /dev/null 2>&1 || true
