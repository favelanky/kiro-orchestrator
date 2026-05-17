#!/usr/bin/env bash
# Orchestrator: runs lead, agents, worker in a loop
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
PROJECT_NAME="{{PROJECT_NAME}}"
WF="$PROJECT/.kiro-workflow"
STATE_DIR="$WF/state"
LEAD_INTERVAL="${KIRO_LEAD_INTERVAL:-3600}"      # max time without lead (sanity ceiling)
MIN_LEAD_INTERVAL="${KIRO_MIN_LEAD_INTERVAL:-60}" # min time between leads (anti-thrash)
COMMIT_FLAG="$WF/.commit-flag"

# Files whose modification triggers lead. Includes .commit-flag (touched by
# git post-commit hook), human channels (answer.md, guidelines.md), state
# files lead needs to react to (tasks.md, messages.md, needs-human.md).
declare -a TRIGGER_FILES=(
  "$WF/.commit-flag"
  "$WF/answer.md"
  "$WF/guidelines.md"
  "$WF/tasks.md"
  "$WF/messages.md"
  "$WF/needs-human.md"
)

# Snapshot of trigger file mtimes. Refreshed AFTER each lead cycle so lead's
# own writes don't re-trigger itself.
declare -A TRIGGER_MTIME

snapshot_triggers() {
  local f
  for f in "${TRIGGER_FILES[@]}"; do
    if [ -e "$f" ]; then
      TRIGGER_MTIME["$f"]=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    else
      TRIGGER_MTIME["$f"]=0
    fi
  done
}

any_trigger_changed() {
  local f cur snap
  for f in "${TRIGGER_FILES[@]}"; do
    [ -e "$f" ] || continue
    cur=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    snap=${TRIGGER_MTIME["$f"]:-0}
    if (( cur > snap )); then
      log "Trigger fired: $(basename "$f") modified ($snap → $cur)"
      return 0
    fi
  done
  return 1
}

# Returns comma-separated list of trigger filenames whose mtime > snapshot.
# Empty string if none changed.
list_changed_triggers() {
  local f cur snap changed=""
  for f in "${TRIGGER_FILES[@]}"; do
    [ -e "$f" ] || continue
    cur=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    snap=${TRIGGER_MTIME["$f"]:-0}
    if (( cur > snap )); then
      changed="${changed:+$changed, }$(basename "$f")"
    fi
  done
  echo "$changed"
}

mkdir -p "$STATE_DIR" "$STATE_DIR/agents"

# Detect inotify-tools so the loop can be event-driven (Issue #1).
# Falls back to polling sleep if not installed.
HAS_INOTIFY=0
if command -v inotifywait >/dev/null 2>&1; then
  HAS_INOTIFY=1
fi

log() { echo "[$(date -Iseconds)] $*"; }

# Send a short Telegram notification (non-blocking, fire-and-forget)
tg_notify() {
  [ -n "${KIRO_TG_BOT_TOKEN:-}" ] && [ -n "${KIRO_TG_CHAT_ID:-}" ] || return 0
  bash "$WF/tg.sh" "$1" &
}

# wait_for_event: block up to <timeout> seconds, waking early on relevant
# events (commit-flag bumped, answer.md or tasks.md modified). Falls back
# to plain sleep if inotify-tools is missing.
wait_for_event() {
  local timeout="$1"
  (( timeout < 1 )) && timeout=1

  if [ "$HAS_INOTIFY" = "1" ]; then
    # Make sure target files exist so inotifywait doesn't error
    local f
    for f in "${TRIGGER_FILES[@]}"; do
      [ -f "$f" ] || : > "$f"
    done
    inotifywait -q -t "$timeout" -e modify -e close_write \
      "${TRIGGER_FILES[@]}" \
      >/dev/null 2>&1 || true
  else
    sleep "$timeout"
  fi
}

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
  local state=$(grep "^\*\*State:\*\*" "$WF/status.md" 2>/dev/null | sed 's/.*\*\* //')
  local task=$(grep "^\*\*Current task:\*\*" "$WF/status.md" 2>/dev/null | sed 's/.*\*\* //' | cut -c1-60)
  local done_count=$(grep -c "^\- \[x\]" "$WF/tasks.md" 2>/dev/null || echo 0)
  local queue_count=$(grep -c "^\- \[ \]" "$WF/tasks.md" 2>/dev/null || echo 0)
  local last_commit=$(git -C "$PROJECT" log --oneline -1 2>/dev/null || echo "none")
  local phase=$(grep "CURRENT\|ACTIVE" "$WF/guidelines.md" 2>/dev/null | head -1 | sed 's/^#* //' | sed 's/[←→] //')

  local msg="📊 *[$PROJECT_NAME]* hourly summary
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

# Initial trigger snapshot. Bootstrap will force a lead run on first iter
# (last_lead==0), but we baseline now so post-snapshot logic works.
snapshot_triggers

while true; do
  now=$(date +%s)

  # --- Pure event-driven lead trigger ---
  # Run lead if:
  #   (a) bootstrap (never ran before), OR
  #   (b) any trigger file's mtime > last snapshot AND ≥ MIN_LEAD_INTERVAL
  #       since last lead (anti-thrash), OR
  #   (c) sanity ceiling: ≥ LEAD_INTERVAL since last lead
  # The trigger snapshot is refreshed AFTER each lead cycle so lead's own
  # writes (e.g., to tasks.md, messages.md) don't re-trigger itself.
  time_since_lead=$(( now - last_lead ))
  should_run_lead=0
  trigger_reason=""
  if (( last_lead == 0 )); then
    should_run_lead=1
    trigger_reason="bootstrap"
  elif (( time_since_lead >= LEAD_INTERVAL )); then
    should_run_lead=1
    trigger_reason="sanity-ceiling (${time_since_lead}s ≥ ${LEAD_INTERVAL}s)"
  elif any_trigger_changed && (( time_since_lead >= MIN_LEAD_INTERVAL )); then
    should_run_lead=1
    trigger_reason="event"
  fi

  if (( should_run_lead == 1 )); then
    # Build the changed-file list for lead to focus on
    if [ "$trigger_reason" = "event" ]; then
      export LEAD_TRIGGERS
      LEAD_TRIGGERS=$(list_changed_triggers)
    elif [ "$trigger_reason" = "bootstrap" ]; then
      export LEAD_TRIGGERS="bootstrap (first run — read everything)"
    else
      export LEAD_TRIGGERS="sanity-ceiling (periodic recheck)"
    fi
    log "Running lead... (reason: $trigger_reason, triggers: $LEAD_TRIGGERS)"
    tg_notify "🔍 *[$PROJECT_NAME]* lead cycle (${LEAD_TRIGGERS})"
    # R8: record start time, not end time
    last_lead=$now
    aggregate_status "lead-reviewing"
    bash "$WF/lead.sh" || { log "Lead failed"; tg_notify "❌ *[$PROJECT_NAME]* lead FAILED"; }
    # Snapshot AFTER lead exits so its own writes don't trigger another run
    snapshot_triggers
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
    log "Queue empty or all blocked ($blocked/$total), waiting for events"
    aggregate_status "idle"
    # Wait until either an event fires or LEAD_INTERVAL is up.
    wait_secs=$(( last_lead + LEAD_INTERVAL - $(date +%s) ))
    (( wait_secs < 5 )) && wait_secs=5
    wait_for_event "$wait_secs"
    continue
  fi

  # Run worker
  log "Running worker..."
  last_commit_before=$(git -C "$PROJECT" rev-parse --short HEAD 2>/dev/null || echo "")
  aggregate_status "active"
  bash "$WF/worker.sh" || log "Worker exited"
  last_commit_after=$(git -C "$PROJECT" rev-parse --short HEAD 2>/dev/null || echo "")
  if [ "$last_commit_before" != "$last_commit_after" ]; then
    commit_msg=$(git -C "$PROJECT" log --oneline -1 2>/dev/null || echo "?")
    tg_notify "✅ *[$PROJECT_NAME]* committed: $commit_msg"
  fi
  aggregate_status "auto"

  # Brief pause before next cycle (events checked at loop top)
  sleep 10
done
