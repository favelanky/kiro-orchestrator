use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Gauge, Paragraph, Tabs, Wrap},
    Frame,
};

use crate::app::{App, ViewMode};

const BORDER: BorderType = BorderType::Rounded;
const TITLE_STYLE: Style = Style::new().fg(Color::White).add_modifier(Modifier::BOLD);
const DIM: Style = Style::new().fg(Color::DarkGray);

fn titled_block(title: &str) -> Block<'_> {
    Block::default()
        .borders(Borders::ALL)
        .border_type(BORDER)
        .title(title)
        .title_style(TITLE_STYLE)
}

pub fn draw(f: &mut Frame, app: &App) {
    match app.view_mode {
        ViewMode::Dashboard | ViewMode::InputAnswer => draw_dashboard(f, app),
        ViewMode::LogView => draw_log_view(f, app),
        ViewMode::MessageScroll => draw_msg_scroll(f, app),
    }
}

fn draw_msg_scroll(f: &mut Frame, app: &App) {
    let area = f.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(3)])
        .split(area);

    let block = titled_block(" Messages ");
    let inner = block.inner(chunks[0]);
    let visible_height = inner.height as usize;

    let data = app.current();
    let all_lines: Vec<&String> = data.messages.as_ref()
        .map(|m| m.lines.iter().filter(|l| !l.trim().is_empty()).collect())
        .unwrap_or_default();

    let start = app.msg_scroll.saturating_sub(visible_height.saturating_sub(1));
    let end = (start + visible_height).min(all_lines.len());

    let lines: Vec<Line> = all_lines[start..end].iter()
        .map(|l| style_msg_line(l))
        .collect();

    f.render_widget(Paragraph::new(lines).block(block), chunks[0]);

    let footer_block = Block::default().borders(Borders::ALL).border_type(BORDER);
    let spans = vec![
        Span::styled("q", Style::default().fg(Color::Yellow)), Span::raw("/"),
        Span::styled("m", Style::default().fg(Color::Yellow)), Span::raw("/"),
        Span::styled("Esc", Style::default().fg(Color::Yellow)), Span::raw(":close "),
        Span::styled("↑/k", Style::default().fg(Color::Yellow)), Span::raw(":up "),
        Span::styled("↓/j", Style::default().fg(Color::Yellow)), Span::raw(":down"),
    ];
    f.render_widget(Paragraph::new(Line::from(spans)).block(footer_block), chunks[1]);
}

fn draw_log_view(f: &mut Frame, app: &App) {
    let area = f.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Min(1), Constraint::Length(3)])
        .split(area);

    let title = format!(" {} ({} lines) ", app.log_file_name(), app.log_lines.len());
    let block = titled_block(&title);
    let inner = block.inner(chunks[0]);
    let visible_height = inner.height as usize;

    let start = app.log_scroll.saturating_sub(visible_height.saturating_sub(1));
    let end = (start + visible_height).min(app.log_lines.len());

    let lines: Vec<Line> = app.log_lines[start..end].iter()
        .map(|l| {
            if l.starts_with("===") {
                Line::from(Span::styled(l.as_str(), Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)))
            } else if l.starts_with('[') && l.len() > 20 && l.chars().nth(25).map_or(false, |c| c == ']') {
                // Bash log() line: [2026-05-17T19:35:32+03:00] ...
                let time = &l[12..17]; // extract HH:MM
                let rest = &l[27..];   // after "] "
                let mut spans = vec![Span::styled(format!("{} ", time), Style::default().fg(Color::DarkGray))];
                spans.extend(parse_bold(rest, Style::default()));
                Line::from(spans)
            } else if l.starts_with("[") && l.len() > 9 && &l[3..4] == ":" && &l[6..7] == ":" && &l[9..10] == "]" {
                // kiro-cli output line: [HH:MM:SS] ...
                let time = &l[1..9]; // HH:MM:SS
                let rest = if l.len() > 11 { &l[11..] } else { "" };
                let mut spans = vec![Span::styled(format!("{} ", time), Style::default().fg(Color::DarkGray))];
                spans.extend(parse_bold(rest, Style::default()));
                Line::from(spans)
            } else {
                Line::from(parse_bold(l, DIM))
            }
        })
        .collect();

    f.render_widget(Paragraph::new(lines).block(block), chunks[0]);

    let footer_block = Block::default().borders(Borders::ALL).border_type(BORDER);
    let spans = vec![
        Span::styled("q", Style::default().fg(Color::Yellow)), Span::raw("/"),
        Span::styled("Esc", Style::default().fg(Color::Yellow)), Span::raw(":close "),
        Span::styled("←/→", Style::default().fg(Color::Yellow)), Span::raw(":switch file "),
        Span::styled("j/k", Style::default().fg(Color::Yellow)), Span::raw(":scroll "),
        Span::styled("C-u/C-d", Style::default().fg(Color::Yellow)), Span::raw(":page"),
    ];
    f.render_widget(Paragraph::new(Line::from(spans)).block(footer_block), chunks[1]);
}

fn draw_dashboard(f: &mut Frame, app: &App) {
    let data = app.current();
    let has_alert = data.needs_human.as_ref()
        .map(|n| !needs_human_open_items(&n.content).is_empty()).unwrap_or(false);
    let is_blocked = data.status.as_ref()
        .map(|s| s.state == "blocked").unwrap_or(false);
    let show_banner = has_alert || is_blocked;

    let mut constraints = vec![Constraint::Length(3)]; // tabs
    let banner_lines = if show_banner {
        if has_alert {
            let content = data.needs_human.as_ref().map(|n| n.content.as_str()).unwrap_or("");
            needs_human_open_items(content).len().max(1)
        } else { 1 }
    } else { 0 };
    if show_banner { constraints.push(Constraint::Length((banner_lines + 2) as u16)); } // +2 for borders
    constraints.extend([
        Constraint::Length(3),  // epoch + progress row
        Constraint::Length(7),  // worker + git row
        Constraint::Min(6),    // tasks + messages row
        Constraint::Length(3), // footer
    ]);

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints(constraints)
        .split(f.area());

    let mut i = 0;
    draw_tabs(f, app, chunks[i]); i += 1;
    if show_banner { draw_banner(f, app, chunks[i], has_alert); i += 1; }

    // Row: epoch + progress
    let top_row = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(65), Constraint::Percentage(35)])
        .split(chunks[i]);
    draw_phase(f, app, top_row[0]);
    draw_progress(f, app, top_row[1]);
    i += 1;

    // Row: worker status + git
    let mid_row = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(chunks[i]);
    draw_worker(f, app, mid_row[0]);
    draw_git(f, app, mid_row[1]);
    i += 1;

    // Row: tasks + messages (messages wider)
    let bottom_row = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(30), Constraint::Percentage(70)])
        .split(chunks[i]);
    draw_tasks_only(f, app, bottom_row[0]);
    draw_messages(f, app, bottom_row[1]);
    i += 1;

    if app.view_mode == ViewMode::InputAnswer {
        draw_input_bar(f, app, chunks[i]);
    } else {
        draw_footer(f, chunks[i]);
    }
}

fn draw_input_bar(f: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BORDER)
        .title(" Answer (Enter: send, Esc: cancel) ")
        .title_style(TITLE_STYLE)
        .border_style(Style::default().fg(Color::Yellow));
    let text = format!("▸ {}", app.input_buf);
    f.render_widget(Paragraph::new(text).block(block), area);
}

fn draw_tabs(f: &mut Frame, app: &App, area: Rect) {
    let titles: Vec<Line> = (0..app.project_paths.len())
        .map(|i| {
            let name = app.project_name(i);
            let data = &app.data[i];
            let alert = data.needs_human.as_ref()
                .map(|n| !needs_human_open_items(&n.content).is_empty()).unwrap_or(false);
            let dot = if data.service_active { "●" } else { "○" };
            let dot_color = if data.service_active { Color::Green } else { Color::Red };
            if alert {
                Line::from(vec![
                    Span::styled(dot, Style::default().fg(dot_color)),
                    Span::styled(format!(" ⚠ {} ", name), Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
                ])
            } else {
                Line::from(vec![
                    Span::styled(dot, Style::default().fg(dot_color)),
                    Span::raw(format!(" {} ", name)),
                ])
            }
        })
        .collect();

    let active_name = app.project_name(app.active_project);
    let title = format!(" kiro-dash › {} ", active_name);

    let tabs = Tabs::new(titles)
        .block(Block::default().borders(Borders::ALL).border_type(BORDER).title(title).title_style(TITLE_STYLE))
        .select(app.active_project)
        .style(DIM)
        .highlight_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD))
        .divider("│");
    f.render_widget(tabs, area);
}

fn draw_banner(f: &mut Frame, app: &App, area: Rect, is_needs_human: bool) {
    let data = app.current();
    let (lines, fg, bg) = if is_needs_human {
        let content = data.needs_human.as_ref().map(|n| n.content.as_str()).unwrap_or("");
        let items = needs_human_open_items(content);
        let display: Vec<Line> = if items.is_empty() {
            vec![Line::from(" ⚠  Attention needed")]
        } else {
            items.iter().map(|item| {
                let mut spans = vec![Span::raw(" ⚠  ")];
                spans.extend(parse_bold(item, Style::default()));
                Line::from(spans)
            }).collect()
        };
        (display, Color::White, Color::Red)
    } else {
        (vec![Line::from(" ⚠  BLOCKED")], Color::Black, Color::Yellow)
    };
    let style = Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BORDER)
        .border_style(Style::default().fg(bg));
    f.render_widget(Paragraph::new(lines).style(style).block(block), area);
}

/// Extract all open items from needs-human.md
fn needs_human_open_items(content: &str) -> Vec<&str> {
    let mut items = Vec::new();
    let mut in_open = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed == "## Open" {
            in_open = true;
            continue;
        }
        if trimmed.starts_with("## ") && in_open {
            break;
        }
        if in_open && trimmed.starts_with("- ") {
            items.push(trimmed.strip_prefix("- ").unwrap_or(trimmed));
        }
    }
    items
}

fn draw_phase(f: &mut Frame, app: &App, area: Rect) {
    let data = app.current();
    let text = data.epoch.as_deref().unwrap_or("—");
    let block = titled_block(" Epoch ");
    f.render_widget(Paragraph::new(text).block(block).wrap(Wrap { trim: true }), area);
}

fn draw_worker(f: &mut Frame, app: &App, area: Rect) {
    let data = app.current();
    let block = titled_block(" Worker Status ");
    let lines = if let Some(ref s) = data.status {
        let elapsed = elapsed_display(&s.last_updated);
        vec![
            Line::from(vec![
                Span::styled("State: ", Style::default().add_modifier(Modifier::BOLD)),
                Span::styled(&s.state, style_for_state(&s.state)),
                Span::styled(format!("  ({})", elapsed), DIM),
            ]),
            Line::from(vec![
                Span::styled("Task: ", Style::default().add_modifier(Modifier::BOLD)),
                Span::raw(&s.current_task),
            ]),
            Line::from(vec![
                Span::styled("Progress: ", Style::default().add_modifier(Modifier::BOLD)),
                Span::raw(&s.progress),
            ]),
            Line::from(vec![
                Span::styled("Blockers: ", Style::default().add_modifier(Modifier::BOLD)),
                if s.blockers == "none" {
                    Span::styled(&s.blockers, DIM)
                } else {
                    Span::styled(&s.blockers, Style::default().fg(Color::Red).add_modifier(Modifier::BOLD))
                },
            ]),
            Line::from(vec![
                Span::styled("Updated: ", Style::default().add_modifier(Modifier::BOLD)),
                Span::styled(&s.last_updated, DIM),
            ]),
        ]
    } else {
        vec![Line::from(Span::styled("No status data", DIM))]
    };
    f.render_widget(Paragraph::new(lines).block(block), area);
}

fn draw_progress(f: &mut Frame, app: &App, area: Rect) {
    let data = app.current();
    if let Some(ref tasks) = data.tasks {
        let total = tasks.current.len() + tasks.queue.len() + tasks.done.len();
        let done = tasks.done.len();
        let blocked = tasks.blocked_count();
        let ratio = if total > 0 { done as f64 / total as f64 } else { 0.0 };
        let label = if blocked > 0 {
            format!("{}/{} done | {} blocked", done, total, blocked)
        } else {
            format!("{}/{} done", done, total)
        };
        let gauge = Gauge::default()
            .block(Block::default().borders(Borders::ALL).border_type(BORDER).title(" Progress ").title_style(TITLE_STYLE))
            .gauge_style(Style::default().fg(Color::Green).bg(Color::DarkGray))
            .ratio(ratio)
            .label(label);
        f.render_widget(gauge, area);
    } else {
        f.render_widget(Paragraph::new("—").block(titled_block(" Progress ")), area);
    }
}

fn draw_tasks_only(f: &mut Frame, app: &App, area: Rect) {
    let data = app.current();
    let block = titled_block(" Tasks ");
    let mut lines = Vec::new();

    if let Some(ref tasks) = data.tasks {
        if !tasks.current.is_empty() {
            lines.push(Line::from(Span::styled("▶ Current:", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD))));
            for t in &tasks.current {
                let style = if t.blocked { Style::default().fg(Color::Red) } else { Style::default() };
                lines.push(Line::from(Span::styled(format!("  {}", t.title), style)));
            }
        }
        if !tasks.queue.is_empty() {
            lines.push(Line::from(Span::styled("◦ Queue:", Style::default().fg(Color::White).add_modifier(Modifier::BOLD))));
            for t in &tasks.queue {
                let style = if t.blocked { Style::default().fg(Color::Red) } else { DIM };
                lines.push(Line::from(Span::styled(format!("  {}", t.title), style)));
            }
        }
        if !tasks.done.is_empty() {
            lines.push(Line::from(Span::styled("✓ Done:", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD))));
            for t in tasks.done.iter().rev().take(5) {
                lines.push(Line::from(Span::styled(format!("  {}", t.title), DIM)));
            }
        }
    } else {
        lines.push(Line::from(Span::styled("No task data", DIM)));
    }

    f.render_widget(Paragraph::new(lines).block(block).wrap(Wrap { trim: true }), area);
}

fn draw_messages(f: &mut Frame, app: &App, area: Rect) {
    let data = app.current();
    let block = titled_block(" Messages ");
    let lines: Vec<Line> = data.messages.as_ref()
        .map(|m| {
            m.lines.iter()
                .filter(|l| !l.trim().is_empty())
                .rev().take(20).collect::<Vec<_>>().into_iter().rev()
                .map(|l| style_msg_line(l))
                .collect()
        })
        .unwrap_or_default();
    f.render_widget(Paragraph::new(lines).block(block).wrap(Wrap { trim: true }), area);
}

fn draw_git(f: &mut Frame, app: &App, area: Rect) {
    let data = app.current();
    let title = if let Some(ref age) = data.last_commit_age {
        format!(" Git ({}) ", age)
    } else {
        " Git ".to_string()
    };
    let block = titled_block(&title);
    let lines: Vec<Line> = if data.git_log.is_empty() {
        vec![Line::from(Span::styled("no commits", DIM))]
    } else {
        data.git_log.iter()
            .map(|l| {
                // Color the hash portion
                let parts: Vec<&str> = l.splitn(2, ' ').collect();
                if parts.len() == 2 {
                    Line::from(vec![
                        Span::styled(parts[0], Style::default().fg(Color::Yellow)),
                        Span::raw(" "),
                        Span::raw(parts[1]),
                    ])
                } else {
                    Line::from(l.as_str())
                }
            })
            .collect()
    };
    f.render_widget(Paragraph::new(lines).block(block).wrap(Wrap { trim: true }), area);
}

fn draw_footer(f: &mut Frame, area: Rect) {
    let block = Block::default().borders(Borders::ALL).border_type(BORDER);
    let spans = vec![
        Span::styled("q", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":quit "),
        Span::styled("c", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":lead "),
        Span::styled("w", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":worker "),
        Span::styled("i", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":input "),
        Span::styled("a", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":answer "),
        Span::styled("t", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":tasks "),
        Span::styled("g", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":guide "),
        Span::styled("l", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":logs "),
        Span::styled("m", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":msgs "),
        Span::styled("r", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":restart "),
        Span::styled("s", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":stop "),
        Span::styled("←/→", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)), Span::raw(":switch"),
    ];
    f.render_widget(Paragraph::new(Line::from(spans)).block(block), area);
}

fn style_msg_line(l: &str) -> Line<'_> {
    let base_style = if l.contains("[lead") {
        Style::default().fg(Color::Blue)
    } else if l.contains("[worker") {
        Style::default().fg(Color::Green)
    } else if l.contains("REJECTED") || l.contains("FAIL") {
        Style::default().fg(Color::Red)
    } else if l.contains("Approved") || l.contains("PASSED") {
        Style::default().fg(Color::Green)
    } else {
        DIM
    };

    Line::from(parse_bold(l, base_style))
}

/// Parse **bold** markers into spans. Segments inside ** get BOLD modifier added.
fn parse_bold<'a>(text: &'a str, base: Style) -> Vec<Span<'a>> {
    let parts: Vec<&str> = text.split("**").collect();
    if parts.len() <= 1 {
        return vec![Span::styled(text, base)];
    }
    parts.iter().enumerate().map(|(i, part)| {
        if i % 2 == 1 {
            Span::styled(*part, base.add_modifier(Modifier::BOLD))
        } else {
            Span::styled(*part, base)
        }
    }).collect()
}

fn style_for_state(state: &str) -> Style {
    match state {
        "active" | "working" => Style::default().fg(Color::Green).add_modifier(Modifier::BOLD),
        "blocked" => Style::default().fg(Color::Red).add_modifier(Modifier::BOLD),
        "idle" => Style::default().fg(Color::Yellow),
        "spec-written" => Style::default().fg(Color::Magenta),
        _ => Style::default(),
    }
}

fn elapsed_display(timestamp: &str) -> String {
    timestamp.split('T').nth(1)
        .map(|t| format!("since {}", &t[..5.min(t.len())]))
        .unwrap_or_else(|| "?".to_string())
}
