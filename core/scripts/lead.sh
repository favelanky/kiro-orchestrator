#!/usr/bin/env bash
# Lead: reviews code, rejects bad work, manages queue, generates tasks
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
LEAD_HOME="$HOME/.kiro-workflow-lead-{{PROJECT_NAME}}"
LOG="$WF/lead.log"
SESSION_FILE="$WF/.lead-session-id"
SESSION_DIR="$HOME/.kiro/sessions/cli"
LOCKFILE="$WF/.lead.lock"
ROLE_FILE="$LEAD_HOME/role.md"
STATE_FILE="$WF/state/lead.state"

mkdir -p "$WF/state"

write_lead_state() {
  local state="$1"
  local tmp="${STATE_FILE}.tmp"
  {
    printf '**State:** %s\n' "$state"
    printf '**Last updated:** %s\n' "$(date -Iseconds)"
  } > "$tmp" && mv "$tmp" "$STATE_FILE"
}

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }
log "=== Lead cycle ==="

# --- R12: Acquire lockfile, validating PID via /proc cmdline ---
if [ -f "$LOCKFILE" ]; then
  lock_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$lock_pid" ] \
      && kill -0 "$lock_pid" 2>/dev/null \
      && grep -qa "lead.sh" "/proc/$lock_pid/cmdline" 2>/dev/null; then
    log "SKIPPED: lead session busy (pid $lock_pid)"
    exit 0
  fi
  rm -f "$LOCKFILE"  # stale or unrelated
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"; write_lead_state "idle"' EXIT
write_lead_state "running"

# --- R5: Skip if a human kiro-cli session is attached to lead's home dir ---
# We hold the lockfile, so any kiro-cli process whose cwd is $LEAD_HOME must be
# a human-attached session (our own kiro-cli call hasn't started yet).
human_attached() {
  local target="$1"
  local pid
  for pid in $(pgrep -f "kiro-cli" 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    local cwd
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo "")
    [ "$cwd" = "$target" ] && return 0
  done
  return 1
}

if human_attached "$LEAD_HOME"; then
  log "SKIPPED: human kiro-cli attached to $LEAD_HOME"
  exit 0
fi

# --- Read answer.md content into prompt, then clear it ---
ANSWER_CONTENT=""
ANSWER_FILE="$WF/answer.md"
if [ -s "$ANSWER_FILE" ] && grep -qv "^#\|^$" "$ANSWER_FILE"; then
  ANSWER_CONTENT=$(cat "$ANSWER_FILE")
  echo "# Human Answers" > "$ANSWER_FILE"
  log "Read and cleared answer.md"
fi

# --- Build prompt: compressed for resume, full only on first run (Issue #3) ---
mkdir -p "$LEAD_HOME"
cd "$LEAD_HOME"

MAX_TIME=600  # 10 min max

# R3: snapshot existing session files BEFORE the call so we can reliably
# identify the new one afterwards (no more --list-sessions | tail -1 race).
PRE_SNAPSHOT=$(mktemp)
ls "$SESSION_DIR"/*.json 2>/dev/null > "$PRE_SNAPSHOT" || true

if [ -f "$SESSION_FILE" ]; then
  RESUME_FLAG="--resume-id"
  RESUME_ARG="$(cat "$SESSION_FILE")"
  PROMPT="Continue your role as LEAD orchestrator for $PROJECT.
(Re-read $ROLE_FILE if you are unsure of the protocol.)

WHAT CHANGED (focus here first): ${LEAD_TRIGGERS:-unknown}
HUMAN ANSWER (process this first, may be empty):
$ANSWER_CONTENT

Run your cycle: only the steps relevant to what changed above.
Skip steps with nothing new. Be efficient."
else
  RESUME_FLAG="--resume"
  RESUME_ARG=""
  PROMPT="You are the LEAD orchestrator for $PROJECT.

FIRST: Read $ROLE_FILE — it defines your role, rules, and full protocol.

WHAT CHANGED: ${LEAD_TRIGGERS:-bootstrap}
HUMAN ANSWER (process this first, may be empty):
$ANSWER_CONTENT

Then run your full cycle as described in role.md."
fi

if [ -n "$RESUME_ARG" ]; then
  timeout "$MAX_TIME" kiro-cli chat --no-interactive --trust-all-tools \
    "$RESUME_FLAG" "$RESUME_ARG" "$PROMPT" 2>&1 \
    | stdbuf -oL tee -a "$LOG" \
    || log "Lead exited (timeout or error)"
else
  timeout "$MAX_TIME" kiro-cli chat --no-interactive --trust-all-tools \
    "$RESUME_FLAG" "$PROMPT" 2>&1 \
    | stdbuf -oL tee -a "$LOG" \
    || log "Lead exited (timeout or error)"
fi

# --- R3: Capture session ID by snapshot-diff (only on first run) ---
if [ ! -f "$SESSION_FILE" ]; then
  for f in "$SESSION_DIR"/*.json; do
    [ -f "$f" ] || continue
    grep -qxF "$f" "$PRE_SNAPSHOT" && continue  # was there before
    cwd=$(python3 -c "import json,sys
try:
  print(json.load(open('$f')).get('cwd',''))
except Exception:
  pass" 2>/dev/null || echo "")
    if [ "$cwd" = "$LEAD_HOME" ]; then
      sid=$(basename "$f" .json)
      echo "$sid" > "$SESSION_FILE"
      log "Captured lead session ID: $sid"
      break
    fi
  done
fi
rm -f "$PRE_SNAPSHOT"

log "=== Lead done ==="
