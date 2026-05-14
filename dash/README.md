# kiro-dash

A TUI dashboard for monitoring [kiro-workflow](https://github.com/your-org/kiro-orchestrator) projects in real time.

## Features

- Multi-project support with tab switching
- Live file watching — panels update automatically when files change
- Auto-discovery of projects containing `.kiro-workflow/` directories
- Full-screen log viewer and message scroller
- Editor integration for quick file edits
- Service control (systemd user units)
- Alert banners for blocked/needs-human states

## Installation

```bash
cargo install --path .
```

## Usage

```bash
# Auto-discover projects from config base paths
kiro-dash

# Specify workflow directories explicitly (takes priority over discovery)
kiro-dash /path/to/project/.kiro-workflow /another/project/.kiro-workflow
```

## Configuration

Config file: `~/.config/kiro-dash/config.toml`

```toml
# Directories to scan for projects (default: ["~"])
base_paths = ["~/projects", "/opt/work"]

# How deep to scan (default: 1)
scan_depth = 2

# Directories to skip during scanning
exclude_dirs = ["node_modules", "target", ".git"]
```

If the config file is missing, defaults are used (`~` scanned at depth 1).

## Hotkeys

| Key | Action |
|-----|--------|
| `q` | Quit |
| `←` / `→` | Switch between projects |
| `a` | Open `answer.md` in `$EDITOR` |
| `p` | Open `phase.md` in `$EDITOR` |
| `t` | Open `tasks.md` in `$EDITOR` |
| `g` | Open `guidelines.md` in `$EDITOR` |
| `l` | Toggle full-screen log view (↑/↓/j/k to scroll, Esc to close) |
| `m` | Toggle full-screen message scroll (↑/↓/j/k to scroll, Esc to close) |
| `r` | Restart `kiro-worker` systemd user service |
| `s` | Restart `kiro-orchestrator` systemd user service |

## Layout

```
┌─────────────────────────────────────────────┐
│ Tabs: [project-a] [project-b]               │
├─────────────────────────────────────────────┤
│ ⚠ NEEDS HUMAN: ...  (alert banner if any)   │
├─────────────────────────────────────────────┤
│ Phase: current phase description             │
├─────────────────────────────────────────────┤
│ Worker Status: state, task, progress, etc.   │
├──────────┬──────────────────┬───────────────┤
│ Tasks    │ Messages         │ Git           │
│ ▶ Current│ [worker] ...     │ abc1234 ...   │
│ ◦ Queue  │ [lead] ...       │               │
│ ✓ Done   │                  │               │
├──────────┴──────────────────┴───────────────┤
│ q:quit a:answer p:phase t:tasks g:guide ... │
└─────────────────────────────────────────────┘
```

## Screenshots

<!-- TODO: Add screenshots -->

## License

See repository root.
