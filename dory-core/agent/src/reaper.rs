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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_child_wait_lock_is_shared_and_exclusive() {
        let guard = managed_child_wait_guard().await;
        // A background reaper sweep only runs while nothing holds the managed wait, so the lock the
        // sweep polls must be the very lock exec waits take.
        assert!(child_wait_lock().try_lock().is_err());
        assert!(tokio::time::timeout(
            std::time::Duration::from_millis(100),
            managed_child_wait_guard()
        )
        .await
        .is_err());

        drop(guard);
        let reacquired = tokio::time::timeout(
            std::time::Duration::from_secs(20),
            managed_child_wait_guard(),
        )
        .await;
        assert!(reacquired.is_ok(), "the released lock must be reacquirable");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_pid1_reaper_does_not_start_outside_pid_1() {
        assert_ne!(unsafe { libc::getpid() }, 1, "tests do not run as PID 1");
        // Starting a `waitpid(-1, ...)` sweep in a non-init process would steal exit statuses from
        // the managed exec waits, so the entry point must be a no-op here: an unrelated child stays
        // waitable by its own spawner.
        start_pid1_reaper_if_needed();

        let child = std::process::Command::new("/bin/sh")
            .args(["-c", "exit 3"])
            .spawn()
            .expect("spawn child");
        let pid = child.id() as libc::pid_t;
        std::mem::forget(child);
        std::thread::sleep(std::time::Duration::from_millis(400));

        let mut status = 0;
        let waited = unsafe { libc::waitpid(pid, &mut status, 0) };
        assert_eq!(waited, pid, "the child was reaped by something else");
        assert!(libc::WIFEXITED(status));
        assert_eq!(libc::WEXITSTATUS(status), 3);
    }
}
