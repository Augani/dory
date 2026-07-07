use crate::hash::{hash_bytes, Hash};
use std::path::Path;

/// One file in a sync tree. `path` is relative to the sync root, forward-slash separated, so a host
/// and a Linux guest agree on it regardless of OS path conventions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    pub mtime_ns: i64,
    pub mode: u32,
    pub hash: Hash,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Manifest {
    pub entries: Vec<FileEntry>,
}

impl Manifest {
    pub fn get(&self, path: &str) -> Option<&FileEntry> {
        self.entries.iter().find(|e| e.path == path)
    }
}

/// Walk `root` recursively and build a manifest of every regular file, with a content hash. Symlinks
/// and special files are skipped (only regular files replicate). Entries are sorted by path so a
/// host and remote produce byte-identical ordering and the reconciler diff is stable.
pub fn walk_manifest(root: &Path) -> std::io::Result<Manifest> {
    let mut entries = Vec::new();
    walk_into(root, root, &mut entries)?;
    entries.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(Manifest { entries })
}

fn walk_into(root: &Path, dir: &Path, out: &mut Vec<FileEntry>) -> std::io::Result<()> {
    for dirent in std::fs::read_dir(dir)? {
        let dirent = dirent?;
        let path = dirent.path();
        // symlink_metadata: do NOT follow symlinks (avoid escaping the tree / cycles).
        let meta = std::fs::symlink_metadata(&path)?;
        let file_type = meta.file_type();
        if file_type.is_dir() {
            walk_into(root, &path, out)?;
        } else if file_type.is_file() {
            let rel = relative_slash(root, &path);
            let contents = std::fs::read(&path)?;
            out.push(FileEntry {
                path: rel,
                size: meta.len(),
                mtime_ns: mtime_ns(&meta),
                mode: mode_of(&meta),
                hash: hash_bytes(&contents),
            });
        }
        // Anything else (symlink, socket, fifo, device) is skipped.
    }
    Ok(())
}

/// Path relative to `root`, forward-slash separated (so a macOS host and a Linux guest agree).
fn relative_slash(root: &Path, path: &Path) -> String {
    let rel = path.strip_prefix(root).unwrap_or(path);
    rel.components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

#[cfg(unix)]
fn mode_of(meta: &std::fs::Metadata) -> u32 {
    use std::os::unix::fs::MetadataExt;
    meta.mode()
}

#[cfg(not(unix))]
fn mode_of(_meta: &std::fs::Metadata) -> u32 {
    0o644
}

fn mtime_ns(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plan::plan;
    use std::fs;

    struct TempTree {
        root: std::path::PathBuf,
    }
    impl TempTree {
        fn new(tag: &str) -> TempTree {
            let root =
                std::env::temp_dir().join(format!("dory-sync-{}-{}", std::process::id(), tag));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            TempTree { root }
        }
        fn write(&self, rel: &str, contents: &str) {
            let p = self.root.join(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, contents).unwrap();
        }
    }
    impl Drop for TempTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn walk_records_relative_paths_sizes_and_content_hashes() {
        let t = TempTree::new("walk");
        t.write("top.txt", "hello");
        t.write("nested/deep/inner.txt", "world!!");

        let m = walk_manifest(&t.root).unwrap();

        let paths: Vec<&str> = m.entries.iter().map(|e| e.path.as_str()).collect();
        // Forward-slash relative paths, sorted for determinism.
        assert_eq!(paths, vec!["nested/deep/inner.txt", "top.txt"]);

        let top = m.get("top.txt").unwrap();
        assert_eq!(top.size, 5);
        assert_eq!(top.hash, crate::hash::hash_bytes(b"hello"));
        let inner = m.get("nested/deep/inner.txt").unwrap();
        assert_eq!(inner.size, 7);
        assert_eq!(inner.hash, crate::hash::hash_bytes(b"world!!"));
    }

    #[test]
    fn identical_trees_walk_to_an_empty_plan() {
        let a = TempTree::new("ident-a");
        let b = TempTree::new("ident-b");
        for t in [&a, &b] {
            t.write("src/main.rs", "fn main() {}");
            t.write("README.md", "# hi");
        }
        let p = plan(
            &walk_manifest(&a.root).unwrap(),
            &walk_manifest(&b.root).unwrap(),
        );
        assert!(
            p.transfer.is_empty() && p.delete.is_empty(),
            "same content -> nothing to do: {p:?}"
        );
    }

    #[test]
    fn a_changed_file_shows_up_as_a_single_transfer() {
        let host = TempTree::new("chg-host");
        let remote = TempTree::new("chg-remote");
        host.write("a.txt", "same");
        remote.write("a.txt", "same");
        host.write("b.txt", "NEW content");
        remote.write("b.txt", "old content");

        let p = plan(
            &walk_manifest(&host.root).unwrap(),
            &walk_manifest(&remote.root).unwrap(),
        );
        assert_eq!(p.transfer, vec!["b.txt".to_string()]);
        assert!(p.delete.is_empty());
    }
}
