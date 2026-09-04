use super::*;
use crate::exec_control::new_exec_control;
use std::os::fd::IntoRawFd;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

struct Fixture {
    control: Arc<AgentControl>,
    root: PathBuf,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    server: Option<std::thread::JoinHandle<()>>,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "dory-exec-control-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let (host, guest) = std::os::unix::net::UnixStream::pair().unwrap();
        guest.set_nonblocking(true).unwrap();
        let (shutdown, receiver) = tokio::sync::oneshot::channel();
        let server = std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async {
                let stream = UnixStream::from_std(guest).unwrap();
                tokio::select! {
                    _ = dory_agent::daemon::serve_conn(stream) => {},
                    _ = receiver => {},
                }
            });
        });
        let control = connect_agent_over_fd(host.into_raw_fd()).unwrap();
        Self {
            control,
            root,
            shutdown: Some(shutdown),
            server: Some(server),
        }
    }

    fn wait_for(&self, path: &Path) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !path.exists() {
            assert!(
                Instant::now() < deadline,
                "guest did not create {}",
                path.display()
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.shutdown.take().unwrap().send(());
        self.server.take().unwrap().join().unwrap();
        std::fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn cancelled_control_never_dispatches_and_is_single_use() {
    let fixture = Fixture::new();
    let token = new_exec_control();
    token.cancel();
    let result = fixture.control.exec_controlled(
        vec!["/usr/bin/touch".into(), "unexpected".into()],
        fixture.root.display().to_string(),
        vec![],
        600_000,
        1024,
        vec![],
        token.clone(),
    );
    assert!(matches!(
        result,
        Err(ExecWaitError::CancelledGuestStateUnknown)
    ));
    assert!(!fixture.root.join("unexpected").exists());
    let reused =
        fixture
            .control
            .exec_controlled(vec![], String::new(), vec![], 0, 0, vec![], token);
    assert!(matches!(reused, Err(ExecWaitError::AlreadyUsed)));
    fixture.control.info().unwrap();
}

#[test]
fn cancellation_unblocks_host_wait_without_claiming_guest_termination() {
    let fixture = Fixture::new();
    let token = new_exec_control();
    let worker_control = fixture.control.clone();
    let worker_token = token.clone();
    let cwd = fixture.root.display().to_string();
    let (sender, receiver) = mpsc::channel();
    let worker = std::thread::spawn(move || {
        sender
            .send(worker_control.exec_controlled(
                vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "printf started > started; sleep 0.4; printf done > done".into(),
                ],
                cwd,
                vec![],
                600_000,
                1024,
                vec![],
                worker_token,
            ))
            .unwrap_or_else(|_| panic!("exec result receiver closed"));
    });
    fixture.wait_for(&fixture.root.join("started"));
    token.cancel();
    assert!(matches!(
        receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
        Err(ExecWaitError::CancelledGuestStateUnknown)
    ));
    worker.join().unwrap();
    // The exec wait releases the runtime lock and its late response cannot be mistaken for info.
    fixture.control.info().unwrap();
    // Explicitly demonstrate the safety contract: cancellation alone does not stop mutation.
    fixture.wait_for(&fixture.root.join("done"));
    assert_eq!(std::fs::read(fixture.root.join("done")).unwrap(), b"done");
}

#[test]
fn queued_exec_can_cancel_while_an_unrelated_rpc_owns_runtime() {
    let fixture = Fixture::new();
    let control = fixture.control.clone();
    let cwd = fixture.root.display().to_string();
    let first = std::thread::spawn(move || {
        control.exec(
            vec![
                "/bin/sh".into(),
                "-c".into(),
                "printf started > started; sleep 2".into(),
            ],
            cwd,
            vec![],
            5_000,
            1024,
        )
    });
    fixture.wait_for(&fixture.root.join("started"));
    let token = new_exec_control();
    let control = fixture.control.clone();
    let token_for_worker = token.clone();
    let (sender, receiver) = mpsc::channel();
    let queued = std::thread::spawn(move || {
        sender
            .send(control.exec_controlled(
                vec!["/bin/true".into()],
                String::new(),
                vec![],
                600_000,
                1024,
                vec![],
                token_for_worker,
            ))
            .unwrap_or_else(|_| panic!("queued exec result receiver closed"))
    });
    token.cancel();
    assert!(matches!(
        receiver.recv_timeout(Duration::from_secs(1)).unwrap(),
        Err(ExecWaitError::CancelledGuestStateUnknown)
    ));
    queued.join().unwrap();
    first.join().unwrap().unwrap();
}

#[test]
fn controlled_exec_preserves_stdin_and_guest_timeout_results() {
    let fixture = Fixture::new();
    let bytes = vec![0, 1, 255, b'\n'];
    let result = fixture
        .control
        .exec_controlled(
            vec!["/bin/cat".into()],
            String::new(),
            vec![],
            5_000,
            1024,
            bytes.clone(),
            new_exec_control(),
        )
        .unwrap();
    assert_eq!(result.stdout, bytes);
    assert_eq!(result.exit_code, 0);
    assert!(!result.timed_out);
    let timeout = fixture
        .control
        .exec_controlled(
            vec!["/bin/sleep".into(), "2".into()],
            String::new(),
            vec![],
            30,
            1024,
            vec![],
            new_exec_control(),
        )
        .unwrap();
    assert!(timeout.timed_out);
    assert_eq!(timeout.exit_code, 124);
}
