//! Single-use cancellation of a host wait. This does not acknowledge guest process termination:
//! a mutating caller must stop and observe its VM before restoring disk or workspace authority.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::Notify;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ExecWaitError {
    #[error("guest exec wait cancelled; guest process state is unknown")]
    CancelledGuestStateUnknown,
    #[error("exec control was already used")]
    AlreadyUsed,
    #[error("{message}")]
    Failed { message: String },
}

#[derive(uniffi::Object)]
pub struct ExecControl {
    claimed: AtomicBool,
    cancelled: AtomicBool,
    notify: Notify,
}

#[uniffi::export]
pub fn new_exec_control() -> Arc<ExecControl> {
    Arc::new(ExecControl {
        claimed: AtomicBool::new(false),
        cancelled: AtomicBool::new(false),
        notify: Notify::new(),
    })
}

#[uniffi::export]
impl ExecControl {
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        // There is at most one claimed waiter. notify_one stores a permit if cancellation
        // crosses its first poll, so cancellation cannot be lost between flag load and await.
        self.notify.notify_one();
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }
}

impl ExecControl {
    pub(crate) fn claim(&self) -> Result<(), ExecWaitError> {
        self.claimed
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| ())
            .map_err(|_| ExecWaitError::AlreadyUsed)
    }

    pub(crate) fn require_active(&self) -> Result<(), ExecWaitError> {
        if self.is_cancelled() {
            Err(ExecWaitError::CancelledGuestStateUnknown)
        } else {
            Ok(())
        }
    }

    pub(crate) async fn cancelled(&self) {
        loop {
            let notified = self.notify.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}
