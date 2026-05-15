mod app;
pub mod config;
pub mod discovery;
mod reader;
mod ui;
mod watcher;

use anyhow::Result;
use clap::Parser;
use crossterm::{
    event::{self, Event, KeyCode},
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand,
};
use ratatui::prelude::*;
use std::io::stdout;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use app::{App, ViewMode};
use config::Config;
use discovery::{discover_projects, expand_tilde};
use watcher::{DiscoveryWatcher, FileWatcher};

#[derive(Parser)]
#[command(name = "kiro-dash", about = "TUI dashboard for kiro-workflow projects")]
struct Cli {
    /// Paths to .kiro-workflow/ directories
    #[arg()]
    workflow_dirs: Vec<PathBuf>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let config = Config::load();

    // Discover projects from config base paths
    let base_paths: Vec<PathBuf> = config.base_paths.iter().map(PathBuf::from).collect();
    let discovered = discover_projects(&base_paths, config.scan_depth);
    // Convert discovered project roots to their .kiro-workflow/ paths
    let discovered_wf: Vec<PathBuf> = discovered.into_iter().map(|p| p.join(".kiro-workflow")).collect();

    // CLI paths take priority (placed first), then discovered
    let cli_dirs: Vec<PathBuf> = cli.workflow_dirs.iter()
        .filter_map(|d| std::fs::canonicalize(d).ok())
        .collect();

    let mut all_dirs = cli_dirs.clone();
    for d in discovered_wf {
        if let Ok(canon) = std::fs::canonicalize(&d) {
            if !all_dirs.contains(&canon) {
                all_dirs.push(canon);
            }
        }
    }

    if all_dirs.is_empty() {
        anyhow::bail!("No .kiro-workflow/ directories found (checked CLI args and discovery)");
    }
    let mut app = App::new(all_dirs.clone());

    let watch_refs: Vec<&Path> = all_dirs.iter().map(|p| p.as_path()).collect();
    let fw = FileWatcher::new(&watch_refs).ok();

    // Watch base paths for new/removed projects
    let expanded_bases: Vec<PathBuf> = base_paths.iter().map(|p| expand_tilde(p)).collect();
    let base_refs: Vec<&Path> = expanded_bases.iter().map(|p| p.as_path()).collect();
    let dw = DiscoveryWatcher::new(&base_refs).ok();

    let scan_depth = config.scan_depth;

    enable_raw_mode()?;
    stdout().execute(EnterAlternateScreen)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout()))?;

    loop {
        terminal.draw(|f| ui::draw(f, &app))?;

        if event::poll(Duration::from_millis(500))? {
            if let Event::Key(key) = event::read()? {
                match app.view_mode {
                    ViewMode::LogView => match key.code {
                        KeyCode::Char('q') | KeyCode::Esc => app.toggle_log_view(),
                        KeyCode::Up | KeyCode::Char('k') => app.log_scroll_up(),
                        KeyCode::Down | KeyCode::Char('j') => app.log_scroll_down(),
                        KeyCode::Char('l') => app.log_switch_next(),
                        KeyCode::Char('h') => app.log_switch_prev(),
                        KeyCode::Char('u') if key.modifiers.contains(event::KeyModifiers::CONTROL) => app.log_scroll_half_up(),
                        KeyCode::Char('d') if key.modifiers.contains(event::KeyModifiers::CONTROL) => app.log_scroll_half_down(),
                        _ => {}
                    },
                    ViewMode::MessageScroll => match key.code {
                        KeyCode::Char('q') | KeyCode::Char('m') | KeyCode::Esc => app.toggle_msg_scroll(),
                        KeyCode::Up | KeyCode::Char('k') => app.msg_scroll_up(),
                        KeyCode::Down | KeyCode::Char('j') => app.msg_scroll_down(),
                        KeyCode::Char('u') if key.modifiers.contains(event::KeyModifiers::CONTROL) => app.msg_scroll_half_up(),
                        KeyCode::Char('d') if key.modifiers.contains(event::KeyModifiers::CONTROL) => app.msg_scroll_half_down(),
                        _ => {}
                    },
                    ViewMode::InputAnswer => match key.code {
                        KeyCode::Esc => app.cancel_input(),
                        KeyCode::Enter => { app.submit_input(); app.reload(); }
                        KeyCode::Backspace => { app.input_buf.pop(); }
                        KeyCode::Char(c) => app.input_buf.push(c),
                        _ => {}
                    },
                    ViewMode::Dashboard => match key.code {
                        KeyCode::Char('q') => { app.should_quit = true; break; }
                        KeyCode::Left => app.switch_left(),
                        KeyCode::Right => app.switch_right(),
                        KeyCode::Char('l') => app.toggle_log_view(),
                        KeyCode::Char('m') => app.toggle_msg_scroll(),
                        KeyCode::Char('i') => app.start_input(),
                        KeyCode::Char(c @ ('a' | 't' | 'g')) => {
                            let file = match c {
                                'a' => "answer.md",
                                't' => "tasks.md",
                                _ => "guidelines.md",
                            };
                            let path = app.project_paths[app.active_project].join(file);
                            open_editor(&mut terminal, &path)?;
                            app.reload();
                        }
                        KeyCode::Char('c') => {
                            let name = app.project_name(app.active_project);
                            let lead_home = format!("{}/.kiro-workflow-lead-{}", std::env::var("HOME").unwrap_or_default(), name);
                            let wf_dir = &app.project_paths[app.active_project];
                            open_lead_session(&mut terminal, &lead_home, wf_dir)?;
                            app.reload();
                        }
                        KeyCode::Char('w') => {
                            let wf_dir = &app.project_paths[app.active_project];
                            open_worker_session(&mut terminal, wf_dir)?;
                            app.reload();
                        }
                        KeyCode::Char('r') => {
                            let name = app.project_name(app.active_project);
                            run_systemctl("restart", &format!("kiro-workflow@{}", name));
                        }
                        KeyCode::Char('s') => {
                            let name = app.project_name(app.active_project);
                            run_systemctl("stop", &format!("kiro-workflow@{}", name));
                        }
                        _ => {}
                    },
                }
            }
        }

        if let Some(ref w) = fw {
            if w.has_changes() {
                app.reload_all();
            }
        }

        if let Some(ref w) = dw {
            if w.has_changes() {
                // Re-run discovery and update project list
                let new_discovered = discover_projects(&base_paths, scan_depth);
                let new_wf: Vec<PathBuf> = new_discovered.into_iter().map(|p| p.join(".kiro-workflow")).collect();
                let mut new_dirs = cli_dirs.clone();
                for d in new_wf {
                    if let Ok(canon) = std::fs::canonicalize(&d) {
                        if !new_dirs.contains(&canon) {
                            new_dirs.push(canon);
                        }
                    }
                }
                if !new_dirs.is_empty() {
                    app.update_projects(new_dirs);
                }
            }
        }
    }

    disable_raw_mode()?;
    stdout().execute(LeaveAlternateScreen)?;
    Ok(())
}

fn open_editor(terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>, path: &Path) -> Result<()> {
    disable_raw_mode()?;
    stdout().execute(LeaveAlternateScreen)?;
    let editor = std::env::var("EDITOR").unwrap_or_else(|_| "vi".to_string());
    Command::new(&editor).arg(path).status()?;
    stdout().execute(EnterAlternateScreen)?;
    enable_raw_mode()?;
    terminal.clear()?;
    Ok(())
}

fn open_lead_session(terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>, lead_home: &str, wf_dir: &Path) -> Result<()> {
    disable_raw_mode()?;
    stdout().execute(LeaveAlternateScreen)?;
    let _ = std::fs::create_dir_all(lead_home);

    // Create lockfile so orchestrator's lead.sh skips
    let lockfile = wf_dir.join(".lead.lock");
    let _ = std::fs::write(&lockfile, std::process::id().to_string());

    let session_file = wf_dir.join(".lead-session-id");
    let session_id = std::fs::read_to_string(&session_file).ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let _status = if let Some(ref id) = session_id {
        Command::new("kiro-cli")
            .args(["chat", "--trust-all-tools", "--resume-id", id])
            .current_dir(lead_home)
            .status()?
    } else {
        Command::new("kiro-cli")
            .args(["chat", "--trust-all-tools", "--resume"])
            .current_dir(lead_home)
            .status()?
    };

    // Remove lockfile
    let _ = std::fs::remove_file(&lockfile);

    stdout().execute(EnterAlternateScreen)?;
    enable_raw_mode()?;
    terminal.clear()?;
    Ok(())
}

fn open_worker_session(terminal: &mut Terminal<CrosstermBackend<std::io::Stdout>>, wf_dir: &Path) -> Result<()> {
    disable_raw_mode()?;
    stdout().execute(LeaveAlternateScreen)?;

    let project_dir = wf_dir.parent().unwrap_or(wf_dir);
    let session_file = wf_dir.join(".worker-session-id");
    let session_id = std::fs::read_to_string(&session_file).ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let _status = if let Some(ref id) = session_id {
        Command::new("kiro-cli")
            .args(["chat", "--trust-all-tools", "--resume-id", id])
            .current_dir(project_dir)
            .status()?
    } else {
        Command::new("kiro-cli")
            .args(["chat", "--trust-all-tools", "--resume"])
            .current_dir(project_dir)
            .status()?
    };

    stdout().execute(EnterAlternateScreen)?;
    enable_raw_mode()?;
    terminal.clear()?;
    Ok(())
}

fn run_systemctl(action: &str, service: &str) {
    let _ = Command::new("systemctl").args(["--user", action, service]).output();
}
