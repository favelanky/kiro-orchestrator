#!/usr/bin/env bash
# Orchestrator: runs lead, agents, worker in a loop
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
LEAD_INTERVAL="${KIRO_LEAD_INTERVAL:-180}"

log() { echo "[$(date -Iseconds)] $*"; }

# Prevent duplicate instances
PIDFILE="$WF/.run.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Already running (pid $(cat "$PIDFILE"))" >&2
  exit 1
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

log "Starting orchestrator"

last_lead=0
last_summary=0
SUMMARY_INTERVAL="${KIRO_SUMMARY_INTERVAL:-3600}"
declare -A last_agent_run

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
    printf '# Worker Status\n\n**State:** lead-reviewing\n**Last updated:** %s\n**Current task:** —\n**Progress:** lead cycle\n**Blockers:** none\n' "$(date -Iseconds)" > "$WF/status.md"
    bash "$WF/lead.sh" || log "Lead failed"
    last_lead=$now
    printf '# Worker Status\n\n**State:** idle\n**Last updated:** %s\n**Current task:** —\n**Progress:** lead done, checking agents/worker\n**Blockers:** none\n' "$(date -Iseconds)" > "$WF/status.md"
  fi

  # Send summary if enough time passed
  if (( now - last_summary >= SUMMARY_INTERVAL )); then
    send_summary
    last_summary=$now
  fi

  # Run custom agents on their intervals
  for agent_dir in "$WF"/agents/*/; do
    [ -d "$agent_dir" ] || continue
    config="$agent_dir/config.toml"
    [ -f "$config" ] || continue
    grep -q 'enabled *= *false' "$config" && continue
    agent_interval=$(grep '^interval' "$config" | sed 's/[^0-9]//g')
    agent_interval="${agent_interval:-600}"
    agent_name=$(basename "$agent_dir")
    last="${last_agent_run[$agent_name]:-0}"
    if (( now - last >= agent_interval )); then
      log "Running agent: $agent_name"
      bash "$WF/agent.sh" "$agent_dir" || log "Agent $agent_name failed"
      last_agent_run[$agent_name]=$now
    fi
  done

  # Skip worker if queue is empty or all tasks are blocked
  total=$(grep -c "^\- \[ \]" "$WF/tasks.md" 2>/dev/null || echo 0)
  blocked=$(grep "^\- \[ \]" "$WF/tasks.md" 2>/dev/null | grep -ci "BLOCKED" || echo 0)
  if [ "$total" -eq 0 ] || [ "$total" -eq "$blocked" ]; then
    log "Queue empty or all blocked ($blocked/$total), skipping worker"
    printf '# Worker Status\n\n**State:** idle\n**Last updated:** %s\n**Current task:** none\n**Progress:** queue empty or blocked (%s/%s)\n**Blockers:** none\n' "$(date -Iseconds)" "$blocked" "$total" > "$WF/status.md"
    sleep 30
    continue
  fi

  # Run worker
  log "Running worker..."
  printf '# Worker Status\n\n**State:** active\n**Last updated:** %s\n**Current task:** (starting)\n**Progress:** worker running\n**Blockers:** none\n' "$(date -Iseconds)" > "$WF/status.md"
  bash "$WF/worker.sh" || log "Worker exited"

  # Brief pause before next cycle
  sleep 10
done
