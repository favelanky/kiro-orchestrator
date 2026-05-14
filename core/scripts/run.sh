#!/usr/bin/env bash
# Orchestrator: continuous worker + periodic lead
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
LEAD_INTERVAL="${KIRO_LEAD_INTERVAL:-180}"
ORCH_LOG="$WF/orchestrator.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$ORCH_LOG"; }

log "Starting orchestrator"

last_lead=0
last_summary=0
SUMMARY_INTERVAL="${KIRO_SUMMARY_INTERVAL:-3600}"

# Send Telegram summary
send_summary() {
  local project_name=$(basename "$PROJECT")
  local state=$(grep "^\*\*State:\*\*" "$WF/status.md" 2>/dev/null | sed 's/.*\*\* //')
  local task=$(grep "^\*\*Current task:\*\*" "$WF/status.md" 2>/dev/null | sed 's/.*\*\* //' | cut -c1-60)
  local done_count=$(grep -c "^\- \[x\]" "$WF/tasks.md" 2>/dev/null || echo 0)
  local queue_count=$(grep -c "^\- \[ \]" "$WF/tasks.md" 2>/dev/null || echo 0)
  local last_commit=$(git -C "$PROJECT" log --oneline -1 2>/dev/null || echo "none")
  local phase=$(grep "CURRENT\|ACTIVE" "$WF/guidelines.md" 2>/dev/null | head -1 | sed 's/^#* //' | sed 's/[←→] //')

  local msg="📊 *[$project_name]* hourly summary
⚡ State: $state
📋 Task: $task
✅ Done: $done_count | 📥 Queue: $queue_count
🔨 Last: $last_commit
🎯 Phase: ${phase:0:80}"

  if [ -n "${KIRO_TG_BOT_TOKEN:-}" ] && [ -n "${KIRO_TG_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${KIRO_TG_BOT_TOKEN}/sendMessage" \
      -d chat_id="$KIRO_TG_CHAT_ID" \
      -d text="$msg" \
      -d parse_mode="Markdown" > /dev/null 2>&1
  fi
  log "Summary sent"
}

while true; do
  now=$(date +%s)

  # Run lead if enough time passed
  if (( now - last_lead >= LEAD_INTERVAL )); then
    log "Running lead..."
    bash "$WF/lead.sh" 2>&1 | tee -a "$ORCH_LOG" || log "Lead failed"
    last_lead=$now
  fi

  # Send summary if enough time passed
  if (( now - last_summary >= SUMMARY_INTERVAL )); then
    send_summary
    last_summary=$now
  fi

  # Skip worker if queue is empty or all tasks are blocked
  total=$(grep -c "^\- \[ \]" "$WF/tasks.md" 2>/dev/null || echo 0)
  blocked=$(grep "^\- \[ \]" "$WF/tasks.md" 2>/dev/null | grep -ci "BLOCKED" || echo 0)
  if [ "$total" -eq 0 ] || [ "$total" -eq "$blocked" ]; then
    log "Queue empty or all blocked ($blocked/$total), skipping worker"
    sleep 30
    continue
  fi

  # Run worker
  log "Running worker..."
  bash "$WF/worker.sh" 2>&1 | tee -a "$ORCH_LOG" || log "Worker exited"

  # Brief pause before next cycle
  sleep 10
done
