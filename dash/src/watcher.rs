use anyhow::Result;
use notify::{Config, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::Path;
use std::sync::mpsc::{self, Receiver, TryRecvError};

pub struct FileWatcher {
    _watcher: RecommendedWatcher,
    rx: Receiver<()>,
}

impl FileWatcher {
    pub fn new(paths: &[&Path]) -> Result<Self> {
        let (tx, rx) = mpsc::channel();
        let mut watcher = RecommendedWatcher::new(
            move |_: notify::Result<notify::Event>| { let _ = tx.send(()); },
            Config::default(),
        )?;
        for path in paths {
            watcher.watch(path, RecursiveMode::Recursive)?;
        }
        Ok(Self { _watcher: watcher, rx })
    }

    pub fn has_changes(&self) -> bool {
        match self.rx.try_recv() {
            Ok(()) => { while self.rx.try_recv().is_ok() {} true }
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => false,
        }
    }
}

/// Watches base paths for new/removed `.kiro-workflow/` directories.
pub struct DiscoveryWatcher {
    _watcher: RecommendedWatcher,
    rx: Receiver<()>,
}

impl DiscoveryWatcher {
    pub fn new(base_paths: &[&Path]) -> Result<Self> {
        let (tx, rx) = mpsc::channel();
        let mut watcher = RecommendedWatcher::new(
            move |res: notify::Result<notify::Event>| {
                if let Ok(event) = res {
                    // Only signal on create/remove events that might involve .kiro-workflow
                    use notify::EventKind::*;
                    match event.kind {
                        Create(_) | Remove(_) => { let _ = tx.send(()); }
                        _ => {}
                    }
                }
            },
            Config::default(),
        )?;
        for path in base_paths {
            // Watch non-recursively — we only care about immediate children
            watcher.watch(path, RecursiveMode::NonRecursive)?;
        }
        Ok(Self { _watcher: watcher, rx })
    }

    pub fn has_changes(&self) -> bool {
        match self.rx.try_recv() {
            Ok(()) => { while self.rx.try_recv().is_ok() {} true }
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => false,
        }
    }
}
