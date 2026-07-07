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
    assert!(converged(&local.path, &remote.path), "remote must be an exact replica");
    assert_eq!(fs::read(remote.path.join("assets/big.bin")).unwrap(), vec![42u8; 700 * 1024]);

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
    assert!(converged(&local.path, &remote.path), "remote converges after edits");
    assert!(!remote.path.join("README.md").exists(), "deleted file removed from replica");
    assert_eq!(
        fs::read(remote.path.join("src/main.rs")).unwrap(),
        b"fn main() { println!(\"changed\"); }"
    );
}
