use anyhow::{Context, Result};
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub struct WorkerStatus {
    pub state: String,
    pub last_updated: String,
    pub current_task: String,
    pub progress: String,
    pub blockers: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Task {
    pub id: String,
    pub title: String,
    pub done: bool,
    pub blocked: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TaskList {
    pub current: Vec<Task>,
    pub queue: Vec<Task>,
    pub done: Vec<Task>,
}

impl TaskList {
    pub fn blocked_count(&self) -> usize {
        self.current.iter().chain(self.queue.iter())
            .filter(|t| t.blocked)
            .count()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Messages {
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NeedsHuman {
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct ProjectData {
    pub status: Option<WorkerStatus>,
    pub tasks: Option<TaskList>,
    pub messages: Option<Messages>,
    pub epoch: Option<String>,
    pub needs_human: Option<NeedsHuman>,
    pub git_log: Vec<String>,
}

impl ProjectData {
    pub fn load(workflow_dir: &Path) -> Self {
        let git_log = load_git_log(workflow_dir);
        Self {
            status: read_and_parse(workflow_dir, "status.md", parse_status).ok(),
            tasks: read_and_parse(workflow_dir, "tasks.md", parse_tasks).ok(),
            messages: read_and_parse(workflow_dir, "messages.md", parse_messages).ok(),
            epoch: read_and_parse(workflow_dir, "guidelines.md", parse_current_epoch).ok().flatten(),
            needs_human: read_and_parse(workflow_dir, "needs-human.md", parse_needs_human).ok(),
            git_log,
        }
    }
}

fn load_git_log(workflow_dir: &Path) -> Vec<String> {
    let project_dir = workflow_dir.parent().unwrap_or(workflow_dir);
    std::process::Command::new("git")
        .args(["-C", &project_dir.to_string_lossy(), "log", "--oneline", "-5"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).lines().map(String::from).collect())
        .unwrap_or_default()
}

fn read_and_parse<T>(dir: &Path, filename: &str, parser: fn(&str) -> Result<T>) -> Result<T> {
    let content = std::fs::read_to_string(dir.join(filename))
        .with_context(|| format!("reading {filename}"))?;
    parser(&content)
}

pub fn parse_status(content: &str) -> Result<WorkerStatus> {
    let mut state = String::new();
    let mut last_updated = String::new();
    let mut current_task = String::new();
    let mut progress = String::new();
    let mut blockers = String::new();

    for line in content.lines() {
        if let Some(val) = line.strip_prefix("**State:**") {
            state = val.trim().to_string();
        } else if let Some(val) = line.strip_prefix("**Last updated:**") {
            last_updated = val.trim().to_string();
        } else if let Some(val) = line.strip_prefix("**Current task:**") {
            current_task = val.trim().to_string();
        } else if let Some(val) = line.strip_prefix("**Progress:**") {
            progress = val.trim().to_string();
        } else if let Some(val) = line.strip_prefix("**Blockers:**") {
            blockers = val.trim().to_string();
        }
    }

    Ok(WorkerStatus { state, last_updated, current_task, progress, blockers })
}

pub fn parse_tasks(content: &str) -> Result<TaskList> {
    let mut current = Vec::new();
    let mut queue = Vec::new();
    let mut done = Vec::new();
    let mut section = "";

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed == "## Current" {
            section = "current";
        } else if trimmed == "## Queue" {
            section = "queue";
        } else if trimmed == "## Done" {
            section = "done";
        } else if let Some(task) = parse_task_line(trimmed) {
            match section {
                "current" => current.push(task),
                "queue" => queue.push(task),
                "done" => done.push(task),
                _ => {}
            }
        }
    }

    Ok(TaskList { current, queue, done })
}

fn parse_task_line(line: &str) -> Option<Task> {
    let (done, rest) = if let Some(r) = line.strip_prefix("- [x]") {
        (true, r)
    } else if let Some(r) = line.strip_prefix("- [ ]") {
        (false, r)
    } else {
        return None;
    };

    let rest = rest.trim();
    let title = if rest.starts_with("**") {
        rest.trim_start_matches("**")
            .split("**")
            .next()
            .unwrap_or(rest)
            .to_string()
    } else {
        rest.to_string()
    };

    let id = title.split(':')
        .next()
        .unwrap_or("")
        .trim()
        .to_string();

    let blocked = rest.to_uppercase().contains("BLOCKED");

    Some(Task { id, title, done, blocked })
}

pub fn parse_messages(content: &str) -> Result<Messages> {
    let lines: Vec<String> = content.lines().map(|l| l.to_string()).collect();
    Ok(Messages { lines })
}

pub fn parse_current_epoch(content: &str) -> Result<Option<String>> {
    for line in content.lines() {
        // Match "← CURRENT" or "(ACTIVE)" markers
        if line.contains("← CURRENT") || line.contains("(ACTIVE)") {
            // Strip markdown heading prefix and clean up
            let clean = line.trim_start_matches('#').trim();
            return Ok(Some(clean.to_string()));
        }
    }
    Ok(None)
}

pub fn parse_needs_human(content: &str) -> Result<NeedsHuman> {
    Ok(NeedsHuman { content: content.trim().to_string() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_status() {
        let input = "# Worker Status\n\n**State:** working\n**Last updated:** 2026-05-14T01:14\n**Current task:** T2: File reader module\n**Progress:** starting\n**Blockers:** none\n";
        let s = parse_status(input).unwrap();
        assert_eq!(s.state, "working");
        assert_eq!(s.current_task, "T2: File reader module");
    }

    #[test]
    fn test_parse_tasks_with_blocked() {
        let input = "# Tasks\n\n## Current\n- [ ] **T2: Do thing** — BLOCKED on data\n\n## Queue\n- [ ] **T3: Other**\n\n## Done\n- [x] **T1: First**\n";
        let t = parse_tasks(input).unwrap();
        assert!(t.current[0].blocked);
        assert!(!t.queue[0].blocked);
        assert_eq!(t.blocked_count(), 1);
    }

    #[test]
    fn test_parse_current_epoch_arrow() {
        let input = "## Epochs\n\n### ✅ Epoch 0: Done\n### → Epoch 1: Active (ACTIVE)\n### Epoch 2: Future\n";
        let e = parse_current_epoch(input).unwrap();
        assert_eq!(e.unwrap(), "→ Epoch 1: Active (ACTIVE)");
    }

    #[test]
    fn test_parse_current_epoch_current_marker() {
        let input = "## Epochs\n\n### Epoch 1: Build stuff ← CURRENT\n";
        let e = parse_current_epoch(input).unwrap();
        assert_eq!(e.unwrap(), "Epoch 1: Build stuff ← CURRENT");
    }

    #[test]
    fn test_parse_current_epoch_none() {
        let input = "## Epochs\n\n### ✅ Epoch 0: Done\n### ✅ Epoch 1: Also done\n";
        let e = parse_current_epoch(input).unwrap();
        assert!(e.is_none());
    }

    #[test]
    fn test_parse_tasks_empty_sections() {
        let input = "# Tasks\n\n## Current\n\n## Queue\n\n## Done\n";
        let t = parse_tasks(input).unwrap();
        assert!(t.current.is_empty());
        assert!(t.queue.is_empty());
        assert!(t.done.is_empty());
    }

    #[test]
    fn test_parse_messages() {
        let input = "**[lead 2026-05-14]** hello\n**[worker 2026-05-14]** done\n";
        let m = parse_messages(input).unwrap();
        assert_eq!(m.lines.len(), 2);
    }

    #[test]
    fn test_parse_needs_human_empty() {
        let n = parse_needs_human("").unwrap();
        assert_eq!(n.content, "");
    }

    #[test]
    fn test_parse_task_line_checked() {
        let task = parse_task_line("- [x] **T1: Scaffold** — done").unwrap();
        assert_eq!(task.id, "T1");
        assert!(task.done);
    }

    #[test]
    fn test_parse_task_line_unchecked() {
        let task = parse_task_line("- [ ] **T5: Editor hotkeys (a/p/t/g)**").unwrap();
        assert_eq!(task.id, "T5");
        assert!(!task.done);
    }

    #[test]
    fn test_parse_task_line_not_a_task() {
        assert!(parse_task_line("  - some sub-item").is_none());
        assert!(parse_task_line("random text").is_none());
    }
}
