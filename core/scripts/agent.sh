#!/usr/bin/env bash
# Generic custom agent runner
# Usage: agent.sh <agent-dir>
# Agent dir must contain config.toml
set -euo pipefail

AGENT_DIR="$1"
AGENT_DIR="${AGENT_DIR%/}"  # normalize: strip trailing slash so cwd matches /proc readlink
PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
CONFIG="$AGENT_DIR/config.toml"
LOG="$AGENT_DIR/agent.log"
SESSION_FILE="$AGENT_DIR/.session-id"
SESSION_DIR="$HOME/.kiro/sessions/cli"
LOCKFILE="$AGENT_DIR/.lock"

if [ ! -f "$CONFIG" ]; then
  echo "No config.toml in $AGENT_DIR" >&2
  exit 1
fi

# Parse config
AGENT_NAME=$(grep '^name' "$CONFIG" | sed 's/.*= *"//' | sed 's/".*//')
PROMPT=$(sed -n '/^prompt *= *"""/,/^"""/p' "$CONFIG" | sed '1d;$d')
HINTS=$(sed -n '/^hints *= *"""/,/^"""/p' "$CONFIG" | sed '1d;$d')

STATE_FILE="$WF/state/agents/${AGENT_NAME}.state"
mkdir -p "$WF/state/agents"

write_agent_state() {
  local state="$1"
  local tmp="${STATE_FILE}.tmp"
  {
    printf '**State:** %s\n' "$state"
    printf '**Last updated:** %s\n' "$(date -Iseconds)"
  } > "$tmp" && mv "$tmp" "$STATE_FILE"
}

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }

# --- R7: Per-agent lockfile, validated by /proc/<pid>/cmdline ---
if [ -f "$LOCKFILE" ]; then
  lock_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$lock_pid" ] \
      && kill -0 "$lock_pid" 2>/dev/null \
      && grep -qa "agent.sh" "/proc/$lock_pid/cmdline" 2>/dev/null; then
    log "SKIPPED: agent '$AGENT_NAME' already running (pid $lock_pid)"
    exit 0
  fi
  rm -f "$LOCKFILE"  # stale or unrelated
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"; write_agent_state "idle"' EXIT
write_agent_state "running"

log "=== Agent '$AGENT_NAME' start ==="

cd "$AGENT_DIR"

# Build the full prompt (used on first run)
FULL_PROMPT="You are a custom agent: $AGENT_NAME

YOUR WORKSPACE: $AGENT_DIR/
You can create any files inside your workspace (scripts/, data/, knowledge/, etc).

RULES:
- You CAN: read any project file, run shell commands, write inside your workspace.
- You CANNOT: write outside your workspace, modify source code, git commit, modify .kiro-workflow scripts, edit tasks.md.
- DO NOT edit messages.md directly. Append via: bash $WF/append-msg.sh '**[$AGENT_NAME TIMESTAMP]** message'
- If you need something built that you can't do yourself, append a request via append-msg.sh.

CONTEXT HINTS:
$HINTS

TASK:
$PROMPT

Do your job now. Write results to your workspace data/ directory."

MAX_TIME=600

# R3: snapshot existing session files BEFORE first-run kiro-cli call
PRE_SNAPSHOT=$(mktemp)
ls "$SESSION_DIR"/*.json 2>/dev/null > "$PRE_SNAPSHOT" || true

if [ -f "$SESSION_FILE" ]; then
  SESSION_ID=$(cat "$SESSION_FILE")
  log "Resuming session $SESSION_ID"
  timeout "$MAX_TIME" kiro-cli chat --no-interactive --trust-all-tools \
    --resume-id "$SESSION_ID" \
    "Continue your job as $AGENT_NAME (workspace: $AGENT_DIR/).
Re-read your config at $CONFIG if you are unsure of the task.
Check if anything changed since last run. Produce updated output." 2>&1 \
    | stdbuf -oL tee -a "$LOG" \
    || log "Agent exited (timeout or error)"
else
  log "First run — full prompt"
  timeout "$MAX_TIME" kiro-cli chat --no-interactive --trust-all-tools --resume \
    "$FULL_PROMPT" 2>&1 | stdbuf -oL tee -a "$LOG" \
      || log "Agent exited (timeout or error)"

  # R3: capture session ID via snapshot-diff (find new file with cwd=$AGENT_DIR)
  for f in "$SESSION_DIR"/*.json; do
    [ -f "$f" ] || continue
    grep -qxF "$f" "$PRE_SNAPSHOT" && continue
    cwd=$(python3 -c "import json
try:
  print(json.load(open('$f')).get('cwd',''))
except Exception:
  pass" 2>/dev/null || echo "")
    if [ "$cwd" = "$AGENT_DIR" ]; then
      sid=$(basename "$f" .json)
      echo "$sid" > "$SESSION_FILE"
      log "Captured session ID: $sid"
      break
    fi
  done
fi

rm -f "$PRE_SNAPSHOT"
log "=== Agent '$AGENT_NAME' end ==="
