#!/usr/bin/env bash
# Worker: continuous mode — loops through tasks until queue is empty
set -euo pipefail

PROJECT="{{PROJECT_PATH}}"
WF="$PROJECT/.kiro-workflow"
LOG="$WF/worker.log"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG"; }
log "=== Worker session start ==="

cd "$PROJECT"
kiro-cli chat --no-interactive --trust-all-tools --resume \
  "You are a WORKER on this project in CONTINUOUS MODE.

FIRST: Read these files NOW (use absolute paths):
- {{PROJECT_PATH}}/.kiro-workflow/tasks.md
- {{PROJECT_PATH}}/.kiro-workflow/patterns.md
- {{PROJECT_PATH}}/.kiro-workflow/messages.md (last 20 lines)

CRITICAL RULES:
- DO NOT rewrite or regenerate the Queue. The lead manages it. Only move items from Queue → Current → Done.
- DO NOT rename or redefine tasks. Implement EXACTLY what is written in the queue.
- DO NOT add new tasks to the queue.
- NEVER modify .kiro-workflow/lead.sh, worker.sh, run.sh, or notify.sh.

CONTINUOUS MODE: Do NOT stop after one task. Keep working until the Queue is empty.

FOR EACH TASK:
1. Move next from Queue → Current (copy it exactly as written)
2. Update status.md: state=active, current task=T<N>
3. If task is [needs-spec]: write spec to .kiro-workflow/specs/T<N>-spec.md, update status to 'spec-written', then STOP
4. Otherwise implement:
   a. Write code
   b. cargo check — if fails, fix (2 attempts max, then git checkout -- . and mark blocked)
   c. cargo test — if fails, fix
   d. git add + commit with message format: T<N>: short description
5. Move task to Done in tasks.md (one-line result with commit hash)
6. Update status.md: state=idle or next task
7. Append to messages.md: **[worker TIMESTAMP]** what you did
8. IMMEDIATELY take next task from Queue and repeat

STOP CONDITIONS (only these):
- Queue is empty
- Task needs spec approval
- Blocker that needs human

For parallelizable subtasks, use the subagent tool to spawn parallel workers.

UNLIMITED BUDGET. Be thorough. Write tests." 2>&1 | tee -a "$LOG"

log "=== Worker session end ==="
