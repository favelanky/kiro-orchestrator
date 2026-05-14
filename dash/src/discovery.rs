use std::fs;
use std::path::{Path, PathBuf};

const SKIP_DIRS: &[&str] = &["node_modules", "target", ".git", ".hg", "dist", "build"];

/// Discover directories containing `.kiro-workflow/` under the given base paths.
pub fn discover_projects(base_paths: &[PathBuf], max_depth: u8) -> Vec<PathBuf> {
    let mut results = Vec::new();
    for base in base_paths {
        let expanded = expand_tilde(base);
        scan_dir(&expanded, max_depth, &mut results);
    }
    results.sort();
    results.dedup();
    results
}

pub fn expand_tilde(path: &Path) -> PathBuf {
    if let Some(s) = path.to_str() {
        if s.starts_with('~') {
            if let Some(home) = dirs_home() {
                return PathBuf::from(s.replacen('~', &home, 1));
            }
        }
    }
    path.to_path_buf()
}

fn dirs_home() -> Option<String> {
    std::env::var("HOME").ok()
}

fn scan_dir(dir: &Path, depth_remaining: u8, results: &mut Vec<PathBuf>) {
    if !dir.is_dir() {
        return;
    }
    // Check if this dir itself has .kiro-workflow/
    if dir.join(".kiro-workflow").is_dir() {
        results.push(dir.to_path_buf());
    }
    if depth_remaining == 0 {
        return;
    }
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            if name.starts_with('.') || SKIP_DIRS.contains(&name) {
                continue;
            }
        }
        scan_dir(&path, depth_remaining - 1, results);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn setup_project(base: &Path, name: &str) -> PathBuf {
        let project = base.join(name);
        fs::create_dir_all(project.join(".kiro-workflow")).unwrap();
        project
    }

    #[test]
    fn discovers_project_at_depth_1() {
        let tmp = TempDir::new().unwrap();
        let proj = setup_project(tmp.path(), "my-project");
        let results = discover_projects(&[tmp.path().to_path_buf()], 1);
        assert_eq!(results, vec![proj]);
    }

    #[test]
    fn skips_hidden_dirs() {
        let tmp = TempDir::new().unwrap();
        setup_project(tmp.path(), ".hidden-project");
        let results = discover_projects(&[tmp.path().to_path_buf()], 1);
        assert!(results.is_empty());
    }

    #[test]
    fn skips_node_modules() {
        let tmp = TempDir::new().unwrap();
        setup_project(tmp.path(), "node_modules");
        let results = discover_projects(&[tmp.path().to_path_buf()], 1);
        assert!(results.is_empty());
    }

    #[test]
    fn skips_target_dir() {
        let tmp = TempDir::new().unwrap();
        setup_project(tmp.path(), "target");
        let results = discover_projects(&[tmp.path().to_path_buf()], 1);
        assert!(results.is_empty());
    }

    #[test]
    fn respects_max_depth_zero() {
        let tmp = TempDir::new().unwrap();
        // Project is at depth 1, but max_depth=0 means only check base itself
        setup_project(tmp.path(), "deep-project");
        let results = discover_projects(&[tmp.path().to_path_buf()], 0);
        assert!(results.is_empty());
    }

    #[test]
    fn finds_base_path_itself_if_it_has_workflow() {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join(".kiro-workflow")).unwrap();
        let results = discover_projects(&[tmp.path().to_path_buf()], 0);
        assert_eq!(results, vec![tmp.path().to_path_buf()]);
    }

    #[test]
    fn multiple_base_paths() {
        let tmp1 = TempDir::new().unwrap();
        let tmp2 = TempDir::new().unwrap();
        let p1 = setup_project(tmp1.path(), "a");
        let p2 = setup_project(tmp2.path(), "b");
        let results = discover_projects(&[tmp1.path().to_path_buf(), tmp2.path().to_path_buf()], 1);
        assert!(results.contains(&p1));
        assert!(results.contains(&p2));
    }

    #[test]
    fn deduplicates_results() {
        let tmp = TempDir::new().unwrap();
        let proj = setup_project(tmp.path(), "dup");
        let results = discover_projects(&[tmp.path().to_path_buf(), tmp.path().to_path_buf()], 1);
        assert_eq!(results.iter().filter(|p| **p == proj).count(), 1);
    }
}
