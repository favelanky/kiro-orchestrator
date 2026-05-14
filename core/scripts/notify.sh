#!/usr/bin/env bash
# Notify human that intervention is needed
MSG="${1:-Lead needs your attention}"
WF="$(dirname "$0")"
PROJECT_NAME=$(basename "$(dirname "$WF")")

# Desktop notification
notify-send "🦊 [$PROJECT_NAME]" "$MSG" 2>/dev/null

# Write to needs-human.md
NOTIFY_FILE="$WF/needs-human.md"
if [ -f "$NOTIFY_FILE" ]; then
  sed -i "/^## Open/a - **$(date +%Y-%m-%dT%H:%M)** — $MSG" "$NOTIFY_FILE"
fi

# Telegram
if [ -n "${KIRO_TG_BOT_TOKEN:-}" ] && [ -n "${KIRO_TG_CHAT_ID:-}" ]; then
  curl -s -X POST "https://api.telegram.org/bot${KIRO_TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="$KIRO_TG_CHAT_ID" \
    -d text="🦊 *[$PROJECT_NAME]* needs you
$MSG" \
    -d parse_mode="Markdown" > /dev/null 2>&1
fi
