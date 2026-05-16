use std::path::PathBuf;
use crate::reader::ProjectData;

fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            // Skip until we hit a letter (end of escape sequence)
            for c2 in chars.by_ref() {
                if c2.is_ascii_alphabetic() || c2 == 'h' {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq)]
pub enum ViewMode {
    Dashboard,
    LogView,
    MessageScroll,
    InputAnswer,
}

pub struct App {
    pub project_paths: Vec<PathBuf>,
    pub active_project: usize,
    pub data: Vec<ProjectData>,
    pub should_quit: bool,
    pub view_mode: ViewMode,
    pub log_lines: Vec<String>,
    pub log_scroll: usize,
    pub log_file_index: usize,
    pub msg_scroll: usize,
    pub input_buf: String,
}

impl App {
    pub fn new(workflow_dirs: Vec<PathBuf>) -> Self {
        let data = workflow_dirs.iter().map(|d| ProjectData::load(d)).collect();
        Self {
            project_paths: workflow_dirs,
            active_project: 0,
            data,
            should_quit: false,
            view_mode: ViewMode::Dashboard,
            log_lines: Vec::new(),
            log_scroll: 0,
            log_file_index: 0,
            msg_scroll: 0,
            input_buf: String::new(),
        }
    }

    pub fn current(&self) -> &ProjectData {
        &self.data[self.active_project]
    }

    pub fn reload(&mut self) {
        self.data[self.active_project] = ProjectData::load(&self.project_paths[self.active_project]);
    }

    pub fn reload_all(&mut self) {
        for (i, p) in self.project_paths.iter().enumerate() {
            self.data[i] = ProjectData::load(p);
        }
    }

    pub fn update_projects(&mut self, new_dirs: Vec<PathBuf>) {
        // Keep active project if still present
        let current = self.project_paths.get(self.active_project).cloned();
        self.project_paths = new_dirs;
        self.data = self.project_paths.iter().map(|d| ProjectData::load(d)).collect();
        if let Some(cur) = current {
            if let Some(idx) = self.project_paths.iter().position(|p| p == &cur) {
                self.active_project = idx;
            } else {
                self.active_project = 0;
            }
        } else {
            self.active_project = 0;
        }
    }

    pub fn project_name(&self, idx: usize) -> &str {
        self.project_paths[idx]
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
    }

    pub fn switch_left(&mut self) {
        if self.project_paths.len() > 1 {
            self.active_project = if self.active_project == 0 {
                self.project_paths.len() - 1
            } else {
                self.active_project - 1
            };
        }
    }

    pub fn switch_right(&mut self) {
        if self.project_paths.len() > 1 {
            self.active_project = (self.active_project + 1) % self.project_paths.len();
        }
    }

    pub fn toggle_log_view(&mut self) {
        if self.view_mode == ViewMode::LogView {
            self.view_mode = ViewMode::Dashboard;
        } else {
            self.log_file_index = 0;
            self.load_logs();
            self.view_mode = ViewMode::LogView;
        }
    }

    const LOG_FILES: [&str; 2] = ["worker.log", "lead.log"];

    pub fn load_logs(&mut self) {
        let wf = &self.project_paths[self.active_project];
        let name = Self::LOG_FILES[self.log_file_index];
        let path = wf.join(name);
        let old_len = self.log_lines.len();
        let was_at_bottom = self.log_scroll >= old_len.saturating_sub(1);

        self.log_lines = if let Ok(bytes) = std::fs::read(&path) {
            let content = String::from_utf8_lossy(&bytes);
            let all: Vec<&str> = content.lines().collect();
            let start = all.len().saturating_sub(500);
            all[start..].iter().map(|l| strip_ansi(l)).collect()
        } else {
            vec![format!("(no {} found at {:?})", name, path)]
        };

        if was_at_bottom {
            self.log_scroll = self.log_lines.len().saturating_sub(1);
        }
    }

    pub fn log_file_name(&self) -> &str {
        Self::LOG_FILES[self.log_file_index]
    }

    pub fn log_switch_next(&mut self) {
        self.log_file_index = (self.log_file_index + 1) % Self::LOG_FILES.len();
        self.load_logs();
    }

    pub fn log_switch_prev(&mut self) {
        self.log_file_index = if self.log_file_index == 0 {
            Self::LOG_FILES.len() - 1
        } else {
            self.log_file_index - 1
        };
        self.load_logs();
    }

    pub fn log_scroll_up(&mut self) {
        self.log_scroll = self.log_scroll.saturating_sub(1);
    }

    pub fn log_scroll_down(&mut self) {
        if self.log_scroll < self.log_lines.len().saturating_sub(1) {
            self.log_scroll += 1;
        }
    }

    pub fn log_scroll_half_up(&mut self) {
        self.log_scroll = self.log_scroll.saturating_sub(20);
    }

    pub fn log_scroll_half_down(&mut self) {
        let max = self.log_lines.len().saturating_sub(1);
        self.log_scroll = (self.log_scroll + 20).min(max);
    }

    pub fn toggle_msg_scroll(&mut self) {
        if self.view_mode == ViewMode::MessageScroll {
            self.view_mode = ViewMode::Dashboard;
        } else {
            self.view_mode = ViewMode::MessageScroll;
            // Start at bottom of messages
            let count = self.msg_line_count();
            self.msg_scroll = count.saturating_sub(1);
        }
    }

    pub fn msg_line_count(&self) -> usize {
        self.current().messages.as_ref()
            .map(|m| m.lines.iter().filter(|l| !l.trim().is_empty()).count())
            .unwrap_or(0)
    }

    pub fn msg_scroll_up(&mut self) {
        self.msg_scroll = self.msg_scroll.saturating_sub(1);
    }

    pub fn msg_scroll_down(&mut self) {
        let max = self.msg_line_count().saturating_sub(1);
        if self.msg_scroll < max {
            self.msg_scroll += 1;
        }
    }

    pub fn msg_scroll_half_up(&mut self) {
        self.msg_scroll = self.msg_scroll.saturating_sub(20);
    }

    pub fn msg_scroll_half_down(&mut self) {
        let max = self.msg_line_count().saturating_sub(1);
        self.msg_scroll = (self.msg_scroll + 20).min(max);
    }

    pub fn start_input(&mut self) {
        self.input_buf.clear();
        self.view_mode = ViewMode::InputAnswer;
    }

    pub fn cancel_input(&mut self) {
        self.input_buf.clear();
        self.view_mode = ViewMode::Dashboard;
    }

    pub fn submit_input(&mut self) {
        if !self.input_buf.is_empty() {
            let path = self.project_paths[self.active_project].join("answer.md");
            let _ = std::fs::write(&path, &self.input_buf);
        }
        self.input_buf.clear();
        self.view_mode = ViewMode::Dashboard;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn make_workflow(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("kiro-t4-{}-{}", name, std::process::id()));
        let wf = dir.join(".kiro-workflow");
        fs::create_dir_all(&wf).unwrap();
        fs::write(wf.join("status.md"), "# Worker Status\n\n**State:** idle\n**Last updated:** now\n**Current task:** none\n**Progress:** -\n**Blockers:** none\n").unwrap();
        fs::write(wf.join("tasks.md"), "# Tasks\n\n## Current\n\n## Queue\n\n## Done\n").unwrap();
        fs::write(wf.join("messages.md"), "").unwrap();
        fs::write(wf.join("guidelines.md"), "## Epochs\n\n### Epoch 1: Test ← CURRENT\n").unwrap();
        fs::write(wf.join("needs-human.md"), "").unwrap();
        wf
    }

    #[test]
    fn test_switch_wraps() {
        let a = make_workflow("a");
        let b = make_workflow("b");
        let mut app = App::new(vec![a.clone(), b.clone()]);
        assert_eq!(app.active_project, 0);
        app.switch_right();
        assert_eq!(app.active_project, 1);
        app.switch_right();
        assert_eq!(app.active_project, 0);
        app.switch_left();
        assert_eq!(app.active_project, 1);
        let _ = fs::remove_dir_all(a.parent().unwrap());
        let _ = fs::remove_dir_all(b.parent().unwrap());
    }

    #[test]
    fn test_single_no_switch() {
        let a = make_workflow("solo");
        let mut app = App::new(vec![a.clone()]);
        app.switch_right();
        assert_eq!(app.active_project, 0);
        app.switch_left();
        assert_eq!(app.active_project, 0);
        let _ = fs::remove_dir_all(a.parent().unwrap());
    }

    #[test]
    fn test_log_view_toggle() {
        let a = make_workflow("log");
        fs::write(a.join("worker.log"), "line1\nline2\nline3").unwrap();
        fs::write(a.join("lead.log"), "lead1\nlead2").unwrap();
        let mut app = App::new(vec![a.clone()]);
        assert_eq!(app.view_mode, ViewMode::Dashboard);
        app.toggle_log_view();
        assert_eq!(app.view_mode, ViewMode::LogView);
        assert!(!app.log_lines.is_empty());
        app.toggle_log_view();
        assert_eq!(app.view_mode, ViewMode::Dashboard);
        let _ = fs::remove_dir_all(a.parent().unwrap());
    }

    #[test]
    fn test_log_scroll() {
        let a = make_workflow("scroll");
        let content: String = (0..50).map(|i| format!("line {}\n", i)).collect();
        fs::write(a.join("worker.log"), &content).unwrap();
        let mut app = App::new(vec![a.clone()]);
        app.toggle_log_view();
        let max = app.log_lines.len().saturating_sub(1);
        assert_eq!(app.log_scroll, max); // starts at bottom
        app.log_scroll_up();
        assert_eq!(app.log_scroll, max - 1);
        app.log_scroll_down();
        assert_eq!(app.log_scroll, max);
        app.log_scroll_down(); // can't go past end
        assert_eq!(app.log_scroll, max);
        let _ = fs::remove_dir_all(a.parent().unwrap());
    }

    #[test]
    fn test_msg_scroll_toggle() {
        let a = make_workflow("msgscroll");
        let content: String = (0..30).map(|i| format!("**[worker]** msg {}\n", i)).collect();
        fs::write(a.join("messages.md"), &content).unwrap();
        let mut app = App::new(vec![a.clone()]);
        assert_eq!(app.view_mode, ViewMode::Dashboard);
        app.toggle_msg_scroll();
        assert_eq!(app.view_mode, ViewMode::MessageScroll);
        assert_eq!(app.msg_scroll, 29); // starts at bottom (30 lines, 0-indexed)
        app.msg_scroll_up();
        assert_eq!(app.msg_scroll, 28);
        app.msg_scroll_down();
        assert_eq!(app.msg_scroll, 29);
        app.toggle_msg_scroll();
        assert_eq!(app.view_mode, ViewMode::Dashboard);
        let _ = fs::remove_dir_all(a.parent().unwrap());
    }

    #[test]
    fn test_inline_input() {
        let a = make_workflow("input");
        let mut app = App::new(vec![a.clone()]);
        app.start_input();
        assert_eq!(app.view_mode, ViewMode::InputAnswer);
        app.input_buf.push_str("hello world");
        app.submit_input();
        assert_eq!(app.view_mode, ViewMode::Dashboard);
        let content = fs::read_to_string(a.join("answer.md")).unwrap();
        assert_eq!(content, "hello world");
        // Test cancel
        app.start_input();
        app.input_buf.push_str("discard");
        app.cancel_input();
        assert_eq!(app.view_mode, ViewMode::Dashboard);
        let content = fs::read_to_string(a.join("answer.md")).unwrap();
        assert_eq!(content, "hello world"); // unchanged
        let _ = fs::remove_dir_all(a.parent().unwrap());
    }
}
