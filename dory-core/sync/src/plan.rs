use crate::manifest::Manifest;

/// The host-authoritative reconciliation of a local (source-of-truth) tree against the remote's
/// current state: which files to send and which to remove so the remote becomes an exact replica.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncPlan {
    /// Relpaths to send: missing on the remote, or present with a different content hash.
    pub transfer: Vec<String>,
    /// Relpaths present on the remote but absent from the host — deleted to make an exact replica.
    pub delete: Vec<String>,
}

pub fn plan(local: &Manifest, remote: &Manifest) -> SyncPlan {
    let transfer = local
        .entries
        .iter()
        .filter(|l| {
            remote
                .get(&l.path)
                .map(|r| r.hash != l.hash)
                .unwrap_or(true)
        })
        .map(|l| l.path.clone())
        .collect();
    let delete = remote
        .entries
        .iter()
        .filter(|r| local.get(&r.path).is_none())
        .map(|r| r.path.clone())
        .collect();
    SyncPlan { transfer, delete }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::FileEntry;

    fn entry(path: &str, hash_byte: u8) -> FileEntry {
        FileEntry {
            path: path.into(),
            size: 1,
            mtime_ns: 0,
            mode: 0o644,
            hash: [hash_byte; 32],
        }
    }

    #[test]
    fn host_authoritative_transfers_changed_and_deletes_extras() {
        let local = Manifest {
            entries: vec![entry("a", 1), entry("b", 2)],
        };
        let remote = Manifest {
            entries: vec![entry("a", 1), entry("b", 3), entry("c", 4)],
        };
        let p = plan(&local, &remote);
        // a: same hash -> skip. b: differs -> transfer. c: only on remote -> delete.
        assert_eq!(p.transfer, vec!["b".to_string()]);
        assert_eq!(p.delete, vec!["c".to_string()]);
    }

    #[test]
    fn empty_remote_transfers_everything_and_deletes_nothing() {
        let local = Manifest {
            entries: vec![entry("a", 1), entry("b", 2)],
        };
        let p = plan(&local, &Manifest::default());
        assert_eq!(p.transfer, vec!["a".to_string(), "b".to_string()]);
        assert!(p.delete.is_empty());
    }

    #[test]
    fn identical_trees_produce_an_empty_plan() {
        let m = Manifest {
            entries: vec![entry("a", 1), entry("dir/b", 2)],
        };
        let p = plan(&m, &m.clone());
        assert!(p.transfer.is_empty(), "no transfers when identical");
        assert!(p.delete.is_empty(), "no deletes when identical");
    }

    #[test]
    fn empty_local_deletes_all_remote() {
        let remote = Manifest {
            entries: vec![entry("a", 1), entry("b", 2)],
        };
        let p = plan(&Manifest::default(), &remote);
        assert!(p.transfer.is_empty());
        assert_eq!(p.delete, vec!["a".to_string(), "b".to_string()]);
    }
}
