#!/usr/bin/env bash
# Lead: reviews code, rejects bad work, manages queue, generates tasks
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
LEAD_HOME="$HOME/.kiro-workflow-lead-{{PROJECT_NAME}}"
LOG="$WF/lead.log"
SESSION_FILE="$WF/.lead-session-id"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }
log "=== Lead cycle ==="

LOCKFILE="$WF/.lead.lock"

# Skip if lead is already running (human connected or another cycle)
if [ -f "$LOCKFILE" ]; then
  lock_pid=$(cat "$LOCKFILE" 2>/dev/null)
  if kill -0 "$lock_pid" 2>/dev/null; then
    log "SKIPPED: lead session busy (pid $lock_pid)"
    exit 0
  else
    rm -f "$LOCKFILE"  # stale lock
  fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# Read answer.md content into prompt, then clear it
ANSWER_CONTENT=""
ANSWER_FILE="$WF/answer.md"
if [ -s "$ANSWER_FILE" ] && grep -qv "^#\|^$" "$ANSWER_FILE"; then
  ANSWER_CONTENT=$(cat "$ANSWER_FILE")
  echo "# Human Answers" > "$ANSWER_FILE"
  log "Read and cleared answer.md"
fi

# Get or create session ID
RESUME_FLAG="--resume"
if [ -f "$SESSION_FILE" ]; then
  RESUME_FLAG="--resume-id $(cat "$SESSION_FILE")"
fi

mkdir -p "$LEAD_HOME"
cd "$LEAD_HOME"

WATCHDOG_INTERVAL=600

kiro-cli chat --no-interactive --trust-all-tools $RESUME_FLAG \
  "You are the LEAD orchestrator with CODE REVIEW authority.
Project: {{PROJECT_PATH}}

Read ALL (absolute paths):
- {{PROJECT_PATH}}/.kiro-workflow/guidelines.md
- {{PROJECT_PATH}}/.kiro-workflow/tasks.md
- {{PROJECT_PATH}}/.kiro-workflow/status.md
- {{PROJECT_PATH}}/.kiro-workflow/messages.md
- {{PROJECT_PATH}}/.kiro-workflow/patterns.md

HUMAN ANSWER (process this first, it's from the human):
$ANSWER_CONTENT

STEP 1 — CODE REVIEW (most important):
Run: git -C {{PROJECT_PATH}} log --oneline -3
For each NEW commit since your last review, run:
  git -C {{PROJECT_PATH}} show <hash> --stat
  git -C {{PROJECT_PATH}} show <hash>
Review against:
- Does it match the task's acceptance criteria?
- Is the code correct? Any obvious bugs?
- Are tests meaningful (not just 'assert true')?
- Does it follow patterns.md conventions?

If a commit is BAD:
- Append to messages: **[lead TIMESTAMP] REJECTED <hash>: reason. Fix: specific instruction.**
- Update tasks.md: move task back to Current with '[fix needed]' prefix
- Worker will see this and fix on next cycle

If commit is GOOD:
- Append: **[lead TIMESTAMP]** Approved <hash>. Brief praise or note.

STEP 2 — SPEC REVIEW:
Check {{PROJECT_PATH}}/.kiro-workflow/specs/ for pending specs.
If spec exists: review it. If good → message 'Spec approved, implement.' If bad → revision notes.

STEP 3 — QUEUE MANAGEMENT:
- If Queue < 3 tasks → generate more from guidelines.md
- BUT if ALL tasks are done and queue is empty → check guidelines.md for the next epoch.
  - If a next epoch exists: update the phase marker to the next epoch, generate tasks for it, and continue.
  - If NO next epoch exists (all epochs done): THEN notify human and stop.
- Keep tasks small (30 min max). Break big work into pieces.
- Mark complex tasks with [needs-spec]
- Format: - [ ] **T<N>: Title** + description + acceptance criteria

STEP 4 — LEARNING (every 10 completed tasks):
Count Done tasks. If divisible by 10, review all recent Done tasks and:
- Update guidelines.md with refined priorities based on what was learned
- Add a 'Retrospective' entry to messages.md

STEP 5 — ESCALATE:
If human input needed: bash {{PROJECT_PATH}}/.kiro-workflow/notify.sh 'REASON'

STEP 6 — TRIM:
If messages.md > 500 lines, summarize old into SUMMARY block at top.

RULES:
- NEVER modify .kiro-workflow/lead.sh, worker.sh, run.sh, agent.sh, or notify.sh.
- You MAY reorder, skip, or mark epochs as done in guidelines.md (e.g. skip a blocked epoch to start the next one).
- You may NOT delete epochs or rewrite their descriptions.
- After processing a HUMAN ANSWER, move the related item from ## Open to ## Resolved in needs-human.md.

CUSTOM AGENTS:
Check .kiro-workflow/agents/*/config.toml for active agents.
- Agents run autonomously on their own interval and write output to their workspace (agents/<name>/data/)
- Read their output if relevant to task planning
- If an agent reports a problem in messages.md, create a worker task to resolve it
- You may edit agents/<name>/config.toml to adjust interval or set enabled=false

Be strict on reviews. Quality > speed. Reject bad code." 2>&1 | stdbuf -oL tee -a "$LOG" &
CLI_PID=$!

# Watchdog: kill if no log output for WATCHDOG_INTERVAL seconds
while kill -0 $CLI_PID 2>/dev/null; do
  size_before=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  sleep "$WATCHDOG_INTERVAL"
  if ! kill -0 $CLI_PID 2>/dev/null; then break; fi
  size_after=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  if [ "$size_before" = "$size_after" ]; then
    log "WATCHDOG: lead hung (no output for ${WATCHDOG_INTERVAL}s), killing"
    kill $CLI_PID 2>/dev/null
    wait $CLI_PID 2>/dev/null
    break
  fi
done
wait $CLI_PID 2>/dev/null

# Capture session ID on first run
if [ ! -f "$SESSION_FILE" ]; then
  SID=$(cd "$LEAD_HOME" && kiro-cli chat --list-sessions 2>&1 | grep "SessionId" | tail -1 | sed 's/.*SessionId: \x1b\[38;5;141m//' | sed 's/\x1b\[0m//')
  if [ -n "$SID" ]; then
    echo "$SID" > "$SESSION_FILE"
    log "Captured lead session ID: $SID"
  fi
fi

log "=== Lead done ==="
