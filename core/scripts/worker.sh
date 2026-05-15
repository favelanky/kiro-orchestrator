#!/usr/bin/env bash
# Worker: executes one task per invocation, then exits for lead to cycle
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
LOG="$WF/worker.log"
SESSION_FILE="$WF/.worker-session-id"
WATCHDOG_INTERVAL=180  # kill if no output for 3 min

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }
log "=== Worker session start ==="

cd "$PROJECT"

# Build the kiro-cli command
if [ -f "$SESSION_FILE" ]; then
  SESSION_ID=$(cat "$SESSION_FILE")
  log "Resuming session $SESSION_ID"
  PROMPT="Read {{PROJECT_PATH}}/.kiro-workflow/tasks.md NOW. Pick the next unchecked item (- [ ]) from Current or Queue. Implement it (one task only), then stop.

Reminder:
- Update status.md (state=active) before starting
- Commit with format: T<N>: short description
- Move task to Done in tasks.md
- Update status.md (state=idle)
- Append to messages.md: **[worker TIMESTAMP]** what you did
- Then STOP."
  kiro-cli chat --no-interactive --trust-all-tools --resume-id "$SESSION_ID" "$PROMPT" 2>&1 | tee -a "$LOG" &
  CLI_PID=$!
else
  log "First run — full prompt"
  PROMPT="You are a WORKER on this project.

FIRST: Read these files (absolute paths):
- {{PROJECT_PATH}}/.kiro-workflow/tasks.md
- {{PROJECT_PATH}}/.kiro-workflow/guidelines.md
- {{PROJECT_PATH}}/.kiro-workflow/patterns.md
- {{PROJECT_PATH}}/.kiro-workflow/messages.md (last 20 lines)

RULES:
- DO NOT rewrite or regenerate the Queue. Only move items: Queue → Current → Done.
- DO NOT rename or redefine tasks. Implement EXACTLY what is written.
- DO NOT add new tasks to the queue.
- NEVER modify .kiro-workflow/*.sh files.
- Implement ONE task, then STOP.

WORKFLOW:
1. Pick next unchecked task from Queue → move to Current
2. Update status.md: state=active, current task
3. Implement:
   a. Write code
   b. Run build/test — if fails, fix (2 attempts max, then mark blocked)
   c. git add + commit with format: T<N>: short description
4. Move task to Done in tasks.md (one-line result with commit hash)
5. Update status.md: state=idle
6. Append to messages.md: **[worker TIMESTAMP]** what you did
7. STOP.

STATUS.MD FORMAT (use exactly this):
# Worker Status

**State:** active (or idle/blocked)
**Last updated:** YYYY-MM-DDTHH:MM+TZ
**Current task:** T<N>: title
**Progress:** brief note
**Blockers:** none (or description)

Do ONE task now, then stop."
  kiro-cli chat --no-interactive --trust-all-tools --resume "$PROMPT" 2>&1 | tee -a "$LOG" &
  CLI_PID=$!
fi

# Watchdog: kill if no log output for WATCHDOG_INTERVAL seconds
while kill -0 $CLI_PID 2>/dev/null; do
  size_before=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  sleep "$WATCHDOG_INTERVAL"
  if ! kill -0 $CLI_PID 2>/dev/null; then break; fi
  size_after=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  if [ "$size_before" = "$size_after" ]; then
    log "WATCHDOG: no output for ${WATCHDOG_INTERVAL}s, killing hung process"
    kill $CLI_PID 2>/dev/null
    wait $CLI_PID 2>/dev/null
    break
  fi
done
wait $CLI_PID 2>/dev/null

# Capture session ID on first run
if [ ! -f "$SESSION_FILE" ]; then
  SID=$(kiro-cli chat --list-sessions 2>&1 | grep "SessionId" | tail -1 | sed 's/.*SessionId: \x1b\[38;5;141m//' | sed 's/\x1b\[0m//')
  if [ -n "$SID" ]; then
    echo "$SID" > "$SESSION_FILE"
    log "Captured worker session ID: $SID"
  fi
fi

log "=== Worker session end ==="
