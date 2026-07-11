//! End-to-end host-authoritative sync over a real transport: the host push driver against the REAL
//! agent daemon (real `sync_apply` doing real filesystem writes), over TCP loopback. Proves the
//! remote becomes a byte-exact replica, that re-push is a no-op, and that edits + deletions
//! converge — the whole reconciler minus the SSH hop (which `ssh.rs` proves separately).

use std::fs;
use std::path::{Path, PathBuf};

use dory_remote::{push, AgentClient};
use dory_sync::{plan, walk_manifest};
use tokio::net::{TcpListener, TcpStream};

struct Tmp {
    path: PathBuf,
}
impl Tmp {
    fn new(tag: &str) -> Tmp {
        let path = std::env::temp_dir().join(format!("dory-e2e-{}-{}", std::process::id(), tag));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Tmp { path }
    }
    fn write(&self, rel: &str, contents: &[u8]) {
        let p = self.path.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, contents).unwrap();
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// The remote is an exact replica iff diffing the two trees yields no work.
fn converged(local: &Path, remote: &Path) -> bool {
    let l = walk_manifest(local).unwrap();
    let r = walk_manifest(remote).unwrap();
    let p = plan(&l, &r);
    p.transfer.is_empty() && p.delete.is_empty()
}

async fn connect_agent() -> AgentClient {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = dory_agent::daemon::serve(listener).await;
    });
    let stream = TcpStream::connect(addr).await.unwrap();
    AgentClient::connect(stream, "doryd-e2e").await.unwrap()
}

#[tokio::test]
async fn push_makes_the_remote_a_byte_exact_replica_and_converges_on_edits() {
    let client = connect_agent().await;
    let local = Tmp::new("local");
    let remote = Tmp::new("remote");
    let remote_root = remote.path.to_string_lossy().into_owned();

    // A tree with a nested dir and a multi-chunk file.
    local.write("README.md", b"# project");
    local.write("src/main.rs", b"fn main() { println!(\"hi\"); }");
    local.write("assets/big.bin", &vec![42u8; 700 * 1024]);

    let stats = push(&local.path, &remote_root, &client).await.unwrap();
    assert_eq!(stats.files_sent, 3);
    assert_eq!(stats.files_deleted, 0);
    assert!(
        converged(&local.path, &remote.path),
        "remote must be an exact replica"
    );
    assert_eq!(
        fs::read(remote.path.join("assets/big.bin")).unwrap(),
        vec![42u8; 700 * 1024]
    );

    // Re-push with no changes: nothing sent or deleted.
    let noop = push(&local.path, &remote_root, &client).await.unwrap();
    assert_eq!(noop.files_sent, 0, "unchanged tree re-push is a no-op");
    assert_eq!(noop.files_deleted, 0);

    // Edit one file, add one, delete one — the remote must converge (including the deletion).
    local.write("src/main.rs", b"fn main() { println!(\"changed\"); }");
    local.write("src/lib.rs", b"pub fn f() {}");
    fs::remove_file(local.path.join("README.md")).unwrap();

    let stats2 = push(&local.path, &remote_root, &client).await.unwrap();
    assert_eq!(stats2.files_sent, 2, "changed + added");
    assert_eq!(stats2.files_deleted, 1, "removed README.md");
    assert!(
        converged(&local.path, &remote.path),
        "remote converges after edits"
    );
    assert!(
        !remote.path.join("README.md").exists(),
        "deleted file removed from replica"
    );
    assert_eq!(
        fs::read(remote.path.join("src/main.rs")).unwrap(),
        b"fn main() { println!(\"changed\"); }"
    );
}

#[tokio::test]
async fn concurrent_identical_pushes_share_progress_without_corrupting_or_failing() {
    // The mux deliberately dispatches RPCs concurrently. Exercise enough fresh transfers to force
    // chunk interleaving: both callers target the exact same staging key and must either append or
    // idempotently ACK matching bytes. Before the fix this failed every probe run with offset 409s
    // (including `offset 262144 ... staged size 0`) or commit-time ENOENT.
    for round in 0..8 {
        let client = connect_agent().await;
        let local = Tmp::new(&format!("concurrent-local-{round}"));
        let remote = Tmp::new(&format!("concurrent-remote-{round}"));
        let remote_root = remote.path.to_string_lossy().into_owned();
        let expected = vec![round as u8; 700 * 1024];
        local.write("assets/big.bin", &expected);

        let (left, right) = tokio::join!(
            push(&local.path, &remote_root, &client),
            push(&local.path, &remote_root, &client),
        );
        assert!(left.is_ok(), "round {round}, left push: {left:?}");
        assert!(right.is_ok(), "round {round}, right push: {right:?}");
        assert_eq!(
            fs::read(remote.path.join("assets/big.bin")).unwrap(),
            expected,
            "round {round}: atomically published bytes"
        );
        assert!(
            converged(&local.path, &remote.path),
            "round {round}: remote converged"
        );
    }
}

#[tokio::test]
async fn concurrent_coalesced_and_conflicting_pushes_keep_content_and_mode_paired() {
    for round in 0..8 {
        let client = connect_agent().await;
        let local_a = Tmp::new(&format!("conflict-a-{round}"));
        let local_b = Tmp::new(&format!("conflict-b-{round}"));
        let remote = Tmp::new(&format!("conflict-remote-{round}"));
        let remote_root = remote.path.to_string_lossy().into_owned();
        let expected_a = vec![0xA1; 700 * 1024];
        let expected_b = vec![0xB2; 700 * 1024];
        local_a.write("same.bin", &expected_a);
        local_b.write("same.bin", &expected_b);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(
                local_a.path.join("same.bin"),
                std::fs::Permissions::from_mode(0o600),
            )
            .unwrap();
            fs::set_permissions(
                local_b.path.join("same.bin"),
                std::fs::Permissions::from_mode(0o644),
            )
            .unwrap();
        }

        // Two A transfers exercise same-hash coalescing while B races a different hash and mode for
        // the same destination. A stale matched-A ACK must never chmod an already-published B inode.
        let (left, middle, right) = tokio::join!(
            push(&local_a.path, &remote_root, &client),
            push(&local_a.path, &remote_root, &client),
            push(&local_b.path, &remote_root, &client),
        );
        assert!(left.is_ok(), "round {round}, A1 push: {left:?}");
        assert!(middle.is_ok(), "round {round}, A2 push: {middle:?}");
        assert!(right.is_ok(), "round {round}, B push: {right:?}");
        let published = fs::read(remote.path.join("same.bin")).unwrap();
        assert!(
            published == expected_a || published == expected_b,
            "round {round}: final atomic file must equal one complete writer"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(remote.path.join("same.bin"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(
                mode,
                if published == expected_a {
                    0o600
                } else {
                    0o644
                },
                "round {round}: mode must belong to the inode content that won"
            );
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn manifest_waits_for_a_staggered_concurrent_delete_and_update() {
    let client = connect_agent().await;
    let local = Tmp::new("staggered-local");
    let remote = Tmp::new("staggered-remote");
    let remote_root = remote.path.to_string_lossy().into_owned();

    // The first push updates one multi-chunk file, then removes a large obsolete tree. Start the
    // second push only after the delete has demonstrably begun but before its tail is removed.
    let updated = vec![0xA5; 700 * 1024];
    local.write("current.bin", &updated);
    remote.write("current.bin", b"old");
    for i in 0..20_000 {
        remote.write(&format!("obsolete/{i:05}.txt"), b"x");
    }
    let first_deleted = remote.path.join("obsolete/00000.txt");
    let last_deleted = remote.path.join("obsolete/19999.txt");

    let first = push(&local.path, &remote_root, &client);
    let second = async {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30);
        while first_deleted.exists() {
            assert!(tokio::time::Instant::now() < deadline, "delete never began");
            tokio::time::sleep(std::time::Duration::from_millis(1)).await;
        }
        assert!(
            last_deleted.exists(),
            "the stagger must observe deletion in progress, not after completion"
        );
        push(&local.path, &remote_root, &client).await
    };

    let (left, right) = tokio::join!(first, second);
    assert!(left.is_ok(), "first push: {left:?}");
    assert!(right.is_ok(), "staggered push: {right:?}");
    assert_eq!(fs::read(remote.path.join("current.bin")).unwrap(), updated);
    assert!(converged(&local.path, &remote.path));
}
