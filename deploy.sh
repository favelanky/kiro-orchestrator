#!/usr/bin/env bash
# Deploy kiro-workflow to a project
# Usage: ./deploy.sh /path/to/project [--start]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE="$SCRIPT_DIR/core"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: $0 /path/to/project \"Your direction for the project\""
  echo ""
  echo "Example:"
  echo "  $0 ~/my-bot \"Trading bot focused on backtesting. Async Rust, use tokio.\""
  echo ""
  echo "The message tells the AI what to focus on when generating guidelines and tasks."
  exit 1
fi

PROJECT="$(realpath "$1")"
PROJECT_NAME="$(basename "$PROJECT")"
HUMAN_DIRECTION="$2"
WF="$PROJECT/.kiro-workflow"
LEAD_HOME="$HOME/.kiro-workflow-lead-$PROJECT_NAME"
START=false
[ "${3:-}" = "--start" ] && START=true

echo "🦊 Deploying kiro-workflow to: $PROJECT"
echo "   Project name: $PROJECT_NAME"
echo ""

# 1. Create .kiro-workflow directory and per-actor state subdirs
mkdir -p "$WF/specs"
mkdir -p "$WF/state/agents"
echo "✓ Created $WF/ (with state/, specs/)"

# 2. Copy and template scripts
for script in run.sh worker.sh lead.sh agent.sh notify.sh append-msg.sh; do
  sed "s|{{PROJECT_PATH}}|$PROJECT|g; s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
    "$CORE/scripts/$script" > "$WF/$script"
  chmod +x "$WF/$script"
done
echo "✓ Installed scripts (run.sh, worker.sh, lead.sh, agent.sh, notify.sh, append-msg.sh)"

# 3. Copy template .md files (don't overwrite existing)
for tmpl in "$CORE/templates/"*.tmpl; do
  target="$WF/$(basename "$tmpl" .tmpl)"
  if [ ! -f "$target" ]; then
    sed "s|{{PROJECT_PATH}}|$PROJECT|g; s|{{PROJECT_NAME}}|$PROJECT_NAME|g; s|{{TIMESTAMP}}|$(date -Iseconds)|g" \
      "$tmpl" > "$target"
  fi
done
echo "✓ Created template .md files (skipped existing)"

# 4. Create lead home directory
mkdir -p "$LEAD_HOME"
echo "✓ Created lead home: $LEAD_HOME"

# 4a. Deploy role.md (lead's full protocol — referenced by compressed lead prompts)
sed "s|{{PROJECT_PATH}}|$PROJECT|g; s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
  "$CORE/templates/role.md.tmpl" > "$LEAD_HOME/role.md"
echo "✓ Deployed lead role.md → $LEAD_HOME/role.md"

# 5. Generate context-aware guidelines and patterns via kiro-cli
if [ ! -s "$WF/guidelines.md" ] || grep -q "{{" "$WF/guidelines.md" 2>/dev/null; then
  echo ""
  echo "📝 Generating guidelines and patterns from project context..."
  cd "$PROJECT"
  kiro-cli chat --no-interactive --trust-all-tools \
    "You are setting up an AI orchestration workflow for the project at: $PROJECT

HUMAN DIRECTION (this is what the developer wants to focus on):
$HUMAN_DIRECTION

Read the project structure and any config files (package.json, Cargo.toml, Makefile, etc).

Then OVERWRITE these two files using the file write tool:

FILE 1: $WF/guidelines.md
Write this structure (fill in real values from what you read):
---
# Guidelines

## Project
$PROJECT_NAME — (one-line description based on what you found)

## Constraints
- Language: (detected language)
- Build: (build command)
- Test: (test command)
- Key conventions you observed

## Epochs

### Epoch 1: Initial Setup ← CURRENT
(3-5 small tasks based on the HUMAN DIRECTION above and what the project needs)
---

FILE 2: $WF/patterns.md
Write this structure:
---
# Codebase Patterns

## Conventions
- (coding style, module structure, error handling patterns you observed)
- (test patterns)
- (commit conventions if any)
---

IMPORTANT: Actually write both files using the file creation tool. Do not just describe them." 2>/dev/null || echo "⚠ kiro-cli generation failed — fill guidelines.md manually"
  echo "✓ Generated guidelines.md and patterns.md"
fi

# 6. Install systemd service
SERVICE_DIR="$HOME/.config/systemd/user"
mkdir -p "$SERVICE_DIR"
SERVICE_FILE="$SERVICE_DIR/kiro-workflow@${PROJECT_NAME}.service"
if [ ! -f "$SERVICE_FILE" ]; then
  cp "$CORE/systemd/kiro-workflow@.service" "$SERVICE_FILE"
  # Replace %i with actual project name for non-template usage
  sed -i "s|%h/%i|$PROJECT|g" "$SERVICE_FILE"
  sed -i "s|(%i)|($PROJECT_NAME)|g" "$SERVICE_FILE"
  systemctl --user daemon-reload
  echo "✓ Installed systemd service: kiro-workflow@${PROJECT_NAME}"
  echo "  Start with: systemctl --user start kiro-workflow@${PROJECT_NAME}"
  echo "  Enable on boot: systemctl --user enable kiro-workflow@${PROJECT_NAME}"
fi

# 7. Add .kiro-workflow/*.log to .gitignore
if [ -f "$PROJECT/.gitignore" ]; then
  grep -q "kiro-workflow/\*.log" "$PROJECT/.gitignore" || echo ".kiro-workflow/*.log" >> "$PROJECT/.gitignore"
else
  echo ".kiro-workflow/*.log" > "$PROJECT/.gitignore"
fi
echo "✓ Updated .gitignore"

# 7a. Install git post-commit hook for event-driven lead trigger (Issue #1).
# The hook touches .kiro-workflow/.commit-flag after each commit so run.sh
# can wake up immediately instead of waiting for the next polling tick.
HOOK_DIR="$PROJECT/.git/hooks"
if [ -d "$HOOK_DIR" ]; then
  HOOK="$HOOK_DIR/post-commit"
  HOOK_MARKER="kiro-workflow event-driven lead trigger"
  if [ -f "$HOOK" ] && ! grep -q "$HOOK_MARKER" "$HOOK"; then
    echo "⚠ Existing post-commit hook found at $HOOK"
    echo "  Append this snippet manually for event-driven lead:"
    echo "    # $HOOK_MARKER"
    echo "    WF=\"\$(git rev-parse --show-toplevel)/.kiro-workflow\""
    echo "    [ -d \"\$WF\" ] && date -Iseconds > \"\$WF/.commit-flag\""
  else
    cat > "$HOOK" <<EOF
#!/bin/sh
# $HOOK_MARKER
WF="\$(git rev-parse --show-toplevel)/.kiro-workflow"
[ -d "\$WF" ] && date -Iseconds > "\$WF/.commit-flag"
EOF
    chmod +x "$HOOK"
    echo "✓ Installed git post-commit hook"
  fi
fi

# 8. Start if requested
if [ "$START" = true ]; then
  systemctl --user start "kiro-workflow@${PROJECT_NAME}" 2>/dev/null || bash "$WF/run.sh" &
  echo "✓ Orchestrator started"
fi

echo ""
echo "🎉 Done! Next steps:"
echo "  1. Review/edit $WF/guidelines.md"
echo "  2. Start: systemctl --user start kiro-workflow@${PROJECT_NAME}"
echo "  3. Monitor: tail -f $WF/orchestrator.log"
echo "  4. Talk to lead: cd $LEAD_HOME && kiro-cli chat --trust-all-tools --resume"
