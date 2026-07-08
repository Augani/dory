//! PID-1 child reaping coordination.
//!
//! Inside the guest, `dory-agent` runs as PID 1 and must reap orphaned service children. Exec RPCs
//! also spawn direct children and wait for their exact exit status. A background `waitpid(-1, ...)`
//! loop can race those managed waits, so both paths share one child-wait lock.

use std::sync::OnceLock;

static CHILD_WAIT_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

fn child_wait_lock() -> &'static tokio::sync::Mutex<()> {
    CHILD_WAIT_LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

pub async fn managed_child_wait_guard() -> tokio::sync::MutexGuard<'static, ()> {
    child_wait_lock().lock().await
}

#[cfg(target_os = "linux")]
pub fn start_pid1_reaper_if_needed() {
    if unsafe { libc::getpid() } != 1 {
        return;
    }
    std::thread::spawn(|| loop {
        if let Ok(_guard) = child_wait_lock().try_lock() {
            reap_available_children();
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    });
}

#[cfg(target_os = "linux")]
fn reap_available_children() {
    loop {
        let mut status = 0;
        let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
        if pid > 0 {
            continue;
        }
        if pid == 0 {
            return;
        }
        match std::io::Error::last_os_error().raw_os_error() {
            Some(code) if code == libc::EINTR => continue,
            Some(code) if code == libc::ECHILD => return,
            _ => return,
        }
    }
}
