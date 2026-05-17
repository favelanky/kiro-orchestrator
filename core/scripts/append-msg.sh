#!/usr/bin/env bash
# Append a line to messages.md atomically (flock-protected) — R1 fix.
# Lead, worker, and agents all use this instead of editing messages.md directly,
# avoiding the read-modify-write race when multiple actors append concurrently.
#
# Usage: append-msg.sh "text to append"
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 'text to append'" >&2
  exit 1
fi

# This script lives in .kiro-workflow/, so dirname(self) is the workflow dir.
WF="$(dirname "$(readlink -f "$0")")"

# Take an exclusive lock on the lockfile, then append. Block up to 10s.
{
  flock -w 10 -x 9 || { echo "append-msg.sh: failed to acquire lock" >&2; exit 1; }
  printf '%s\n' "$1" >> "$WF/messages.md"
} 9>"$WF/.messages.lock"
