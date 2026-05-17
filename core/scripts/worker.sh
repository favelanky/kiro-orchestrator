#!/usr/bin/env bash
# Worker: executes one task per invocation, then exits for lead to cycle
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
LOG="$WF/worker.log"
SESSION_FILE="$WF/.worker-session-id"
SESSION_DIR="$HOME/.kiro/sessions/cli"

# Default budget (single-file feature). Lead may override per-task with
# [budget=Ns] annotation on the task line. We clamp to [60s, 3600s].
DEFAULT_BUDGET=600
MIN_BUDGET=60
MAX_BUDGET=3600

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }
log "=== Worker session start ==="

cd "$PROJECT"

# --- Issue #2: parse [budget=Ns] from next unchecked, non-blocked task ---
NEXT_LINE=$(grep "^- \[ \]" "$WF/tasks.md" 2>/dev/null \
            | grep -vi "BLOCKED" \
            | head -1 || true)

BUDGET="$DEFAULT_BUDGET"
if [ -n "$NEXT_LINE" ]; then
  # Pattern: [budget=600s] or [budget=600]
  if [[ "$NEXT_LINE" =~ \[budget=([0-9]+)s?\] ]]; then
    BUDGET="${BASH_REMATCH[1]}"
  fi
fi
# Clamp
(( BUDGET < MIN_BUDGET )) && BUDGET=$MIN_BUDGET
(( BUDGET > MAX_BUDGET )) && BUDGET=$MAX_BUDGET
log "Budget for next task: ${BUDGET}s"

# --- R3: snapshot session files BEFORE first-run kiro-cli call ---
PRE_SNAPSHOT=$(mktemp)
ls "$SESSION_DIR"/*.json 2>/dev/null > "$PRE_SNAPSHOT" || true

if [ -f "$SESSION_FILE" ]; then
  SESSION_ID=$(cat "$SESSION_FILE")
  log "Resuming session $SESSION_ID"
  timeout "$BUDGET" kiro-cli chat --no-interactive --trust-all-tools \
    --resume-id "$SESSION_ID" \
    "Read $WF/tasks.md NOW. Pick the next unchecked item (- [ ]) from Current or Queue (skip BLOCKED). Implement that one task, then stop.

Reminder:
- Write $WF/state/worker.state (state=active, current task, progress) before starting
- Commit with format: T<N>: short description
- Move task to Done in tasks.md
- Update $WF/state/worker.state (state=idle) when done
- Announce via: bash $WF/append-msg.sh '**[worker TIMESTAMP]** what you did'
- Then STOP." 2>&1 | stdbuf -oL tee -a "$LOG" \
      || log "Worker exited (timeout or error)"
else
  log "First run — full prompt"
  timeout "$BUDGET" kiro-cli chat --no-interactive --trust-all-tools --resume \
    "You are a WORKER on this project.

FIRST: Read these files (absolute paths):
- $WF/tasks.md
- $WF/guidelines.md
- $WF/patterns.md
- $WF/messages.md (last 20 lines)

RULES:
- DO NOT rewrite or regenerate the Queue. Only move items: Queue → Current → Done.
- DO NOT rename or redefine tasks. Implement EXACTLY what is written.
- DO NOT add new tasks to the queue (that is the lead's job).
- NEVER modify .kiro-workflow/*.sh files.
- DO NOT write status.md directly — write to $WF/state/worker.state instead.
- DO NOT edit messages.md directly — append via: bash $WF/append-msg.sh '...'
- Implement ONE task, then STOP.

WORKFLOW:
1. Pick next unchecked task from Queue → move to Current
2. Write $WF/state/worker.state: state=active, current task
3. Implement:
   a. Write code
   b. Run build/test — if fails, fix (2 attempts max, then mark blocked)
   c. git add + commit with format: T<N>: short description
4. Move task to Done in tasks.md (one-line result with commit hash)
5. Write $WF/state/worker.state: state=idle
6. Announce via: bash $WF/append-msg.sh '**[worker TIMESTAMP]** what you did'
7. STOP.

STATE FILE FORMAT ($WF/state/worker.state — use exactly this):
**State:** active (or idle/blocked)
**Last updated:** YYYY-MM-DDTHH:MM+TZ
**Current task:** T<N>: title
**Progress:** brief note
**Blockers:** none (or description)

Do ONE task now, then stop." 2>&1 | stdbuf -oL tee -a "$LOG" \
      || log "Worker exited (timeout or error)"

  # R3: capture session ID via snapshot-diff (find new file with cwd=$PROJECT)
  for f in "$SESSION_DIR"/*.json; do
    [ -f "$f" ] || continue
    grep -qxF "$f" "$PRE_SNAPSHOT" && continue
    cwd=$(python3 -c "import json
try:
  print(json.load(open('$f')).get('cwd',''))
except Exception:
  pass" 2>/dev/null || echo "")
    if [ "$cwd" = "$PROJECT" ]; then
      sid=$(basename "$f" .json)
      echo "$sid" > "$SESSION_FILE"
      log "Captured worker session ID: $sid"
      break
    fi
  done
fi

rm -f "$PRE_SNAPSHOT"
log "=== Worker session end ==="
