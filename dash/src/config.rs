use serde::Deserialize;
use std::fs;
use std::path::PathBuf;

const CONFIG_PATH: &str = "~/.config/kiro-dash/config.toml";

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(default)]
pub struct Config {
    pub base_paths: Vec<String>,
    pub scan_depth: u8,
    pub exclude_dirs: Vec<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            base_paths: vec!["~".to_string()],
            scan_depth: 1,
            exclude_dirs: vec![
                "node_modules".into(),
                "target".into(),
                ".git".into(),
            ],
        }
    }
}

impl Config {
    pub fn load() -> Self {
        Self::load_from(CONFIG_PATH)
    }

    fn load_from(path: &str) -> Self {
        let expanded = expand_path(path);
        match fs::read_to_string(&expanded) {
            Ok(content) => toml::from_str(&content).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }
}

fn expand_path(path: &str) -> PathBuf {
    if path.starts_with('~') {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(path.replacen('~', &home, 1));
        }
    }
    PathBuf::from(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn defaults_when_file_missing() {
        let cfg = Config::load_from("/nonexistent/path/config.toml");
        assert_eq!(cfg, Config::default());
        assert_eq!(cfg.base_paths, vec!["~".to_string()]);
        assert_eq!(cfg.scan_depth, 1);
    }

    #[test]
    fn parses_full_config() {
        let mut f = NamedTempFile::new().unwrap();
        writeln!(f, r#"
base_paths = ["/home/user/projects", "/opt/work"]
scan_depth = 3
exclude_dirs = ["vendor", "dist"]
"#).unwrap();
        let cfg = Config::load_from(f.path().to_str().unwrap());
        assert_eq!(cfg.base_paths, vec!["/home/user/projects", "/opt/work"]);
        assert_eq!(cfg.scan_depth, 3);
        assert_eq!(cfg.exclude_dirs, vec!["vendor", "dist"]);
    }

    #[test]
    fn partial_config_uses_defaults_for_missing() {
        let mut f = NamedTempFile::new().unwrap();
        writeln!(f, r#"scan_depth = 2"#).unwrap();
        let cfg = Config::load_from(f.path().to_str().unwrap());
        assert_eq!(cfg.base_paths, vec!["~".to_string()]);
        assert_eq!(cfg.scan_depth, 2);
        assert_eq!(cfg.exclude_dirs, vec!["node_modules", "target", ".git"]);
    }

    #[test]
    fn invalid_toml_falls_back_to_defaults() {
        let mut f = NamedTempFile::new().unwrap();
        writeln!(f, "not valid {{{{ toml").unwrap();
        let cfg = Config::load_from(f.path().to_str().unwrap());
        assert_eq!(cfg, Config::default());
    }
}
