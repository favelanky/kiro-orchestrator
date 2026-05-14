# kiro-orchestrator

Autonomous AI development workflow. A **lead** reviews code and manages tasks, a **worker** implements them. You set direction via epochs — the system does the rest.

## Quick Start

```bash
./deploy.sh /path/to/project "Your direction: what to build, focus areas, constraints"
```

## Architecture

```
┌───────────────────────────────────────┐
│            run.sh (loop)              │
│                                       │
│  ┌─────────┐       ┌──────────┐      │
│  │  Lead   │──────▶│  Worker  │      │
│  │ (3 min) │       │(continuous)     │
│  └────┬────┘       └─────┬────┘      │
│       │                   │           │
│       ▼                   ▼           │
│  reviews commits     implements      │
│  manages queue       tests & commits │
│  generates tasks                     │
└───────────────────────────────────────┘
         │                    │
         ▼                    ▼
   .kiro-workflow/*.md    git commits
   (the protocol)         (the output)
```

### The Protocol (`.kiro-workflow/` files)

| File | Purpose | Who writes |
|------|---------|-----------|
| `guidelines.md` | Project vision, constraints, epochs | Human |
| `tasks.md` | Queue → Current → Done | Lead manages, Worker moves |
| `status.md` | Worker's current state | Worker |
| `messages.md` | Lead ↔ Worker conversation | Both |
| `patterns.md` | Codebase conventions | Worker discovers, Lead refines |
| `answer.md` | Human answers to lead questions | Human |
| `needs-human.md` | Escalation log | Lead |

### Roles

**Human** — Sets direction via `guidelines.md` epochs. Answers questions in `answer.md`. Never needs to touch code.

**Lead** — Runs every 3 min. Reviews new commits (approves or rejects with fix instructions). Manages the task queue. Generates new tasks from the current epoch. Escalates blockers to human via Telegram/desktop notification.

**Worker** — Runs continuously until queue is empty. Picks tasks, writes code, runs tests, commits. Follows the "do not rewrite queue" rule — only moves items through the pipeline.

### How Tasks Flow

```
Human writes epoch in guidelines.md
  → Lead generates tasks into Queue
    → Worker moves task to Current, implements, commits
      → Lead reviews commit (approve/reject)
        → Task moves to Done
```

## Useful Commands

```bash
# Talk to the lead directly (ask questions, give direction)
cd ~/.kiro-workflow-lead-<project> && kiro-cli chat --trust-all-tools --resume

# Talk to the worker (see what it's doing)
cd /path/to/project && kiro-cli chat --trust-all-tools --resume

# Answer a question from the lead
echo "Your answer" >> /path/to/project/.kiro-workflow/answer.md

# Check what's happening
tail -f /path/to/project/.kiro-workflow/orchestrator.log

# See worker output
tail -f /path/to/project/.kiro-workflow/worker.log

# See lead decisions
tail -f /path/to/project/.kiro-workflow/lead.log

# Restart the orchestrator
systemctl --user restart kiro-workflow@<project>

# Stop everything
systemctl --user stop kiro-workflow@<project>

# Check service status
systemctl --user status kiro-workflow@<project>
```

## Deploy to a New Project

```bash
./deploy.sh /home/user/my-project "Build a REST API with auth. Use axum + sqlx. Start with user CRUD."
```

What it does:
1. Copies orchestration scripts to `.kiro-workflow/`
2. Uses kiro-cli to read your project and generate context-aware `guidelines.md` and `patterns.md` based on your direction
3. Installs a systemd user service
4. Creates the lead's home directory (`~/.kiro-workflow-lead-<name>`)

After deploy, review `guidelines.md` and start:
```bash
systemctl --user start kiro-workflow@my-project
systemctl --user enable kiro-workflow@my-project  # start on boot
```

## Configuration

Environment variables (set in systemd service or shell):

| Variable | Default | Description |
|----------|---------|-------------|
| `KIRO_LEAD_INTERVAL` | 180 | Seconds between lead cycles |
| `KIRO_SUMMARY_INTERVAL` | 3600 | Seconds between Telegram summaries |
| `KIRO_TG_BOT_TOKEN` | — | Telegram bot token for notifications |
| `KIRO_TG_CHAT_ID` | — | Telegram chat ID |

## Repo Structure

```
kiro-orchestrator/
├── README.md
├── deploy.sh           — Bootstrap new projects
├── core/
│   ├── scripts/        — run.sh, worker.sh, lead.sh, notify.sh
│   ├── templates/      — .md file templates
│   └── systemd/        — Templated service file
└── dash/               — kiro-dash TUI monitor
```

## Dashboard (kiro-dash)

TUI that monitors all kiro-workflow projects at a glance.

```bash
cd dash && cargo run
```

Auto-discovers projects with `.kiro-workflow/` in your home directory. Hotkeys: `←/→` switch project, `a` answer, `t` tasks, `g` guidelines, `r` restart worker, `q` quit.
