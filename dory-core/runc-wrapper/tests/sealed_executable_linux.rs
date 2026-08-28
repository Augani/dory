#![cfg(target_os = "linux")]

use dory_runc_wrapper::{clone_sealed_executable, sealed_executable_path};
use std::fs::File;
use std::os::unix::io::AsRawFd;
use std::process::Command;

const REQUIRED_EXECUTABLE_SEALS: libc::c_int =
    libc::F_SEAL_SEAL | libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_WRITE;

#[test]
fn sealed_executable_clone_is_runc_recognizable_after_exec() {
    let executable = clone_sealed_executable(&std::env::current_exe().unwrap()).unwrap();
    let seals = unsafe { libc::fcntl(executable.as_raw_fd(), libc::F_GET_SEALS) };
    assert_ne!(seals, -1);
    assert_eq!(seals & REQUIRED_EXECUTABLE_SEALS, REQUIRED_EXECUTABLE_SEALS);

    // A descriptor-path exec alone is not the runc contract. runc 1.2.3 opens the new process's
    // /proc/self/exe and skips its failing nested overlay clone only when these base seals survive
    // exec. Re-exec this harness from the memfd and have the child check that exact observation.
    assert!(Command::new(sealed_executable_path(&executable))
        .args([
            "--exact",
            "sealed_executable_child_observes_proc_self_exe_seals",
            "--nocapture",
        ])
        .env("DORY_SEALED_EXECUTABLE_TEST_CHILD", "1")
        .status()
        .unwrap()
        .success());
}

#[test]
fn sealed_executable_child_observes_proc_self_exe_seals() {
    if std::env::var_os("DORY_SEALED_EXECUTABLE_TEST_CHILD").is_none() {
        return;
    }
    let self_executable = File::open("/proc/self/exe").unwrap();
    let seals = unsafe { libc::fcntl(self_executable.as_raw_fd(), libc::F_GET_SEALS) };
    assert_ne!(seals, -1, "executed /proc/self/exe is not a sealable memfd");
    assert_eq!(
        seals & REQUIRED_EXECUTABLE_SEALS,
        REQUIRED_EXECUTABLE_SEALS,
        "executed /proc/self/exe does not satisfy runc's base memfd seal contract"
    );
}
