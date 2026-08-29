//! End-to-end guest-to-host transfer over the real agent RPC spine. The source is served by the
//! production agent handler; the host pull driver must reconstruct a digest-exact private tree,
//! preserve empty directories, and exclude the agent's private push staging namespace.

use std::fs;
use std::path::PathBuf;

use dory_remote::{pull, AgentClient, PullLimits};
use dory_sync::{walk_tree, walk_tree_excluding};
use tokio::net::{TcpListener, TcpStream};

struct PrivateTemp {
    path: PathBuf,
}

impl PrivateTemp {
    fn new(tag: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "dory-pull-e2e-{}-{}-{}",
            std::process::id(),
            tag,
            rand::random::<u64>()
        ));
        fs::create_dir(&path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        Self { path }
    }

    fn write(&self, relative: &str, contents: &[u8]) {
        let path = self.path.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }
}

impl Drop for PrivateTemp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

async fn connect_agent() -> AgentClient {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let _ = dory_agent::daemon::serve(listener).await;
    });
    let stream = TcpStream::connect(address).await.unwrap();
    AgentClient::connect(stream, "doryd-pull-e2e")
        .await
        .unwrap()
}

#[tokio::test]
async fn pull_reconstructs_the_real_agent_tree_with_exact_content() {
    let client = connect_agent().await;
    let guest = PrivateTemp::new("guest");
    let host_parent = PrivateTemp::new("host");
    let host = host_parent.path.join("verified");

    guest.write("README.md", b"guest export");
    guest.write("nested/big.bin", &vec![0x5a; 700 * 1024]);
    fs::create_dir_all(guest.path.join("empty/deep")).unwrap();
    guest.write(".dory-sync-tmp/private", b"must not leave the guest");

    let stats = pull(
        &guest.path.to_string_lossy(),
        &host,
        &client,
        PullLimits::default(),
    )
    .await
    .unwrap();

    assert_eq!(stats.files_received, 2);
    assert_eq!(stats.directories_received, 3);
    assert_eq!(stats.bytes_received, 12 + 700 * 1024);
    assert_eq!(fs::read(host.join("README.md")).unwrap(), b"guest export");
    assert_eq!(
        fs::read(host.join("nested/big.bin")).unwrap(),
        vec![0x5a; 700 * 1024]
    );
    assert!(host.join("empty/deep").is_dir());
    assert!(!host.join(".dory-sync-tmp").exists());

    let expected = walk_tree_excluding(&guest.path, &[".dory-sync-tmp"]).unwrap();
    let actual = walk_tree(&host).unwrap();
    assert_eq!(actual.manifest, expected.manifest);
    assert_eq!(
        actual
            .directories
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>(),
        expected
            .directories
            .iter()
            .map(|entry| entry.path.as_str())
            .collect::<Vec<_>>()
    );
}
