#!/usr/bin/env bash
# Generic custom agent runner
# Usage: agent.sh <agent-dir>
# Agent dir must contain config.toml
set -euo pipefail

AGENT_DIR="$1"
PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
CONFIG="$AGENT_DIR/config.toml"
LOG="$AGENT_DIR/agent.log"
SESSION_FILE="$AGENT_DIR/.session-id"

if [ ! -f "$CONFIG" ]; then
  echo "No config.toml in $AGENT_DIR" >&2
  exit 1
fi

# Parse config
AGENT_NAME=$(grep '^name' "$CONFIG" | sed 's/.*= *"//' | sed 's/".*//')
PROMPT=$(sed -n '/^prompt *= *"""/,/^"""/p' "$CONFIG" | sed '1d;$d')
HINTS=$(sed -n '/^hints *= *"""/,/^"""/p' "$CONFIG" | sed '1d;$d')

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }
log "=== Agent '$AGENT_NAME' start ==="

cd "$PROJECT"

# Build the full prompt
FULL_PROMPT="You are a custom agent: $AGENT_NAME

YOUR WORKSPACE: $AGENT_DIR/
You can create any files inside your workspace (scripts/, data/, knowledge/, etc).

RULES:
- You CAN: read any project file, run shell commands, write inside your workspace, append to $WF/messages.md
- You CANNOT: write outside your workspace, modify source code, git commit, modify .kiro-workflow scripts
- If you need something built that you can't do yourself, append to messages.md: **[$AGENT_NAME TIMESTAMP]** request for lead/worker

CONTEXT HINTS:
$HINTS

TASK:
$PROMPT

Do your job now. Write results to your workspace data/ directory."

if [ -f "$SESSION_FILE" ]; then
  SESSION_ID=$(cat "$SESSION_FILE")
  log "Resuming session $SESSION_ID"
  kiro-cli chat --no-interactive --trust-all-tools --resume-id "$SESSION_ID" \
    "Continue your job as $AGENT_NAME. Check if anything changed since last run. Produce updated output." 2>&1 | stdbuf -oL tee -a "$LOG" &
  CLI_PID=$!
else
  log "First run — full prompt"
  kiro-cli chat --no-interactive --trust-all-tools --resume \
    "$FULL_PROMPT" 2>&1 | stdbuf -oL tee -a "$LOG" &
  CLI_PID=$!
fi

# Watchdog: kill if no log output for 3 min
WATCHDOG_INTERVAL=600
while kill -0 $CLI_PID 2>/dev/null; do
  size_before=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  sleep "$WATCHDOG_INTERVAL"
  if ! kill -0 $CLI_PID 2>/dev/null; then break; fi
  size_after=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  if [ "$size_before" = "$size_after" ]; then
    log "WATCHDOG: agent $AGENT_NAME hung (no output for ${WATCHDOG_INTERVAL}s), killing"
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
    log "Captured session ID: $SID"
  fi
fi

log "=== Agent '$AGENT_NAME' end ==="
