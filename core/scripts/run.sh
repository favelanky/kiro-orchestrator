#!/usr/bin/env bash
# Orchestrator: runs lead, agents, worker in a loop
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
STATE_DIR="$WF/state"
LEAD_INTERVAL="${KIRO_LEAD_INTERVAL:-180}"

mkdir -p "$STATE_DIR" "$STATE_DIR/agents"

log() { echo "[$(date -Iseconds)] $*"; }

# Prevent duplicate instances (validate via /proc/<pid>/cmdline so we don't
# treat a recycled PID as our own — R6/R12)
PIDFILE="$WF/.run.pid"
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$pid" ] \
      && kill -0 "$pid" 2>/dev/null \
      && grep -qa "run.sh" "/proc/$pid/cmdline" 2>/dev/null; then
    echo "Already running (pid $pid)" >&2
    exit 1
  fi
  rm -f "$PIDFILE"  # stale or unrelated PID
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

log "Starting orchestrator"

last_lead=0
last_summary=0
SUMMARY_INTERVAL="${KIRO_SUMMARY_INTERVAL:-3600}"
declare -A last_agent_run

# --- Issue #4 + R2: aggregate per-actor state files into status.md ---
# Single writer for status.md = run.sh. The lead/worker/agents write to their
# own state files in $STATE_DIR; this function regenerates status.md on every
# phase transition.
#
# phase argument:
#   "lead-reviewing" | "active" | "idle"   - explicit override (used during
#                                            phase transitions)
#   "auto"                                  - derive from state/worker.state
aggregate_status() {
  local phase="$1"
  local primary_state="$phase"
  local task="—" prog="—" blockers="none"
  local last
  last=$(date -Iseconds)

  # In auto mode, use worker.state's reported fields as the headline
  if [ "$phase" = "auto" ]; then
    primary_state=""  # reset; will fill from worker.state or fallback to idle
    if [ -f "$STATE_DIR/worker.state" ]; then
      primary_state=$(grep -m1 "^\*\*State:\*\*" "$STATE_DIR/worker.state" 2>/dev/null | sed 's/^\*\*[^*]*\*\* *//' || true)
      task=$(grep -m1 "^\*\*Current task:\*\*" "$STATE_DIR/worker.state" 2>/dev/null | sed 's/^\*\*[^*]*\*\* *//' || true)
      prog=$(grep -m1 "^\*\*Progress:\*\*" "$STATE_DIR/worker.state" 2>/dev/null | sed 's/^\*\*[^*]*\*\* *//' || true)
      blockers=$(grep -m1 "^\*\*Blockers:\*\*" "$STATE_DIR/worker.state" 2>/dev/null | sed 's/^\*\*[^*]*\*\* *//' || true)
      last_from_state=$(grep -m1 "^\*\*Last updated:\*\*" "$STATE_DIR/worker.state" 2>/dev/null | sed 's/^\*\*[^*]*\*\* *//' || true)
      [ -n "${last_from_state:-}" ] && last="$last_from_state"
    fi
    [ -z "$primary_state" ] && primary_state="idle"
    [ -z "$task" ]          && task="—"
    [ -z "$prog" ]          && prog="—"
    [ -z "$blockers" ]      && blockers="none"
  fi

  {
    printf '# Worker Status\n\n'
    printf '**State:** %s\n' "$primary_state"
    printf '**Last updated:** %s\n' "$last"
    printf '**Current task:** %s\n' "$task"
    printf '**Progress:** %s\n' "$prog"
    printf '**Blockers:** %s\n' "$blockers"
    printf '\n## Detail\n'

    # Detail blocks: indent by 2 spaces so dash's strip_prefix("**State:**")
    # doesn't shadow the headline above. Humans see the same content.
    printf '\n### Lead\n'
    if [ -f "$STATE_DIR/lead.state" ]; then sed 's/^/  /' "$STATE_DIR/lead.state"; else echo "  (no state)"; fi

    printf '\n### Worker\n'
    if [ -f "$STATE_DIR/worker.state" ]; then sed 's/^/  /' "$STATE_DIR/worker.state"; else echo "  (no state)"; fi

    if [ -d "$STATE_DIR/agents" ]; then
      for f in "$STATE_DIR/agents"/*.state; do
        [ -f "$f" ] || continue
        printf '\n### Agent: %s\n' "$(basename "$f" .state)"
        sed 's/^/  /' "$f"
      done
    fi
  } > "$WF/status.md.tmp" && mv "$WF/status.md.tmp" "$WF/status.md"
}

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

# Initial status.md
aggregate_status "idle"

while true; do
  now=$(date +%s)

  # Run lead if enough time passed
  if (( now - last_lead >= LEAD_INTERVAL )); then
    log "Running lead..."
    # R8: record start time, not end time
    last_lead=$now
    aggregate_status "lead-reviewing"
    bash "$WF/lead.sh" || log "Lead failed"
    aggregate_status "auto"
  fi

  # Send summary if enough time passed
  if (( now - last_summary >= SUMMARY_INTERVAL )); then
    send_summary
    last_summary=$now
  fi

  # Run custom agents on their intervals (background, non-blocking)
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
      log "Running agent: $agent_name (background)"
      bash "$WF/agent.sh" "$agent_dir" &
      last_agent_run[$agent_name]=$now
    fi
  done

  # Skip worker if queue is empty or all tasks are blocked
  total=$(grep -c "^\- \[ \]" "$WF/tasks.md" 2>/dev/null || echo 0)
  blocked=$(grep "^\- \[ \]" "$WF/tasks.md" 2>/dev/null | grep -ci "BLOCKED" || echo 0)
  if [ "$total" -eq 0 ] || [ "$total" -eq "$blocked" ]; then
    log "Queue empty or all blocked ($blocked/$total), skipping worker"
    aggregate_status "idle"
    sleep 30
    continue
  fi

  # Run worker
  log "Running worker..."
  aggregate_status "active"
  bash "$WF/worker.sh" || log "Worker exited"
  aggregate_status "auto"

  # Brief pause before next cycle
  sleep 10
done
