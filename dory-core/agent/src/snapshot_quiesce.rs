use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use dory_pb::agent::{
    snapshot_quiesce_request::Action, SnapshotQuiesceRequest, SnapshotQuiesceResponse,
};

const QUIESCE_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Debug, Eq, PartialEq)]
enum QuiesceState {
    Freezing(String),
    Frozen(String),
    Thawing(String),
}

fn state() -> &'static Mutex<Option<QuiesceState>> {
    static STATE: OnceLock<Mutex<Option<QuiesceState>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(None))
}

pub fn available() -> bool {
    binary().is_some()
}

pub async fn run(request: SnapshotQuiesceRequest) -> SnapshotQuiesceResponse {
    match Action::try_from(request.action) {
        Ok(Action::Freeze) => freeze(request.receipt_id).await,
        Ok(Action::Thaw) => thaw(request.receipt_id).await,
        _ => response(false, "snapshot quiesce action is invalid", ""),
    }
}

async fn freeze(request_receipt: String) -> SnapshotQuiesceResponse {
    if !valid_receipt(&request_receipt) {
        return response(false, "freeze request has an invalid receipt", "");
    }
    let Some(binary) = binary() else {
        return response(false, "filesystem freeze is unavailable in this guest", "");
    };
    let receipt = request_receipt;
    {
        let mut current = state()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if current.is_some() {
            return response(false, "a snapshot quiesce operation is already active", "");
        }
        *current = Some(QuiesceState::Freezing(receipt.clone()));
    }

    let result = command(binary, "-f").await;
    let mut current = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match result {
        Ok(()) => {
            *current = Some(QuiesceState::Frozen(receipt.clone()));
            response(true, "", &receipt)
        }
        Err(detail) => {
            if *current == Some(QuiesceState::Freezing(receipt.clone())) {
                *current = None;
            }
            response(false, &detail, "")
        }
    }
}

async fn thaw(receipt: String) -> SnapshotQuiesceResponse {
    if !valid_receipt(&receipt) {
        return response(false, "thaw request has an invalid receipt", "");
    }
    let Some(binary) = binary() else {
        return response(false, "filesystem freeze is unavailable in this guest", "");
    };
    {
        let mut current = state()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *current != Some(QuiesceState::Frozen(receipt.clone())) {
            return response(false, "thaw receipt does not match the active freeze", "");
        }
        *current = Some(QuiesceState::Thawing(receipt.clone()));
    }

    let result = command(binary, "-u").await;
    let mut current = state()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match result {
        Ok(()) => {
            *current = None;
            response(true, "", "")
        }
        Err(detail) => {
            if *current == Some(QuiesceState::Thawing(receipt.clone())) {
                *current = Some(QuiesceState::Frozen(receipt));
            }
            response(false, &detail, "")
        }
    }
}

async fn command(binary: &str, action: &str) -> Result<(), String> {
    let mut command = tokio::process::Command::new(binary);
    command.args([action, "/"]).kill_on_drop(true);
    match tokio::time::timeout(QUIESCE_TIMEOUT, command.output()).await {
        Ok(Ok(output)) if output.status.success() => Ok(()),
        Ok(Ok(output)) => {
            let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
            Err(if detail.is_empty() {
                "filesystem freeze command failed".to_string()
            } else {
                detail
            })
        }
        Ok(Err(error)) => Err(format!("filesystem freeze command failed: {error}")),
        Err(_) => Err("filesystem freeze command timed out".to_string()),
    }
}

fn valid_receipt(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn response(completed: bool, detail: &str, receipt_id: &str) -> SnapshotQuiesceResponse {
    SnapshotQuiesceResponse {
        completed,
        detail: detail.chars().take(512).collect(),
        receipt_id: receipt_id.to_string(),
    }
}

#[cfg(target_os = "linux")]
fn binary() -> Option<&'static str> {
    ["/usr/sbin/fsfreeze", "/sbin/fsfreeze"]
        .into_iter()
        .find(|candidate| Path::new(candidate).is_file())
}

#[cfg(not(target_os = "linux"))]
fn binary() -> Option<&'static str> {
    let _ = Path::new("/");
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_unspecified_action_without_touching_the_host() {
        let result = run(SnapshotQuiesceRequest {
            action: Action::Unspecified as i32,
            receipt_id: String::new(),
        })
        .await;
        assert!(!result.completed);
        assert!(result.detail.contains("invalid"));
    }

    #[tokio::test]
    async fn rejects_missing_and_malformed_thaw_receipts_without_touching_the_host() {
        for receipt_id in [String::new(), "A".repeat(32), "a".repeat(31)] {
            let result = run(SnapshotQuiesceRequest {
                action: Action::Thaw as i32,
                receipt_id,
            })
            .await;
            assert!(!result.completed);
            assert!(result.detail.contains("receipt"));
        }
    }

    #[tokio::test]
    async fn rejects_missing_and_malformed_freeze_receipts_without_touching_the_host() {
        for receipt_id in [String::new(), "A".repeat(32), "a".repeat(31)] {
            let result = run(SnapshotQuiesceRequest {
                action: Action::Freeze as i32,
                receipt_id,
            })
            .await;
            assert!(!result.completed);
            assert!(result.detail.contains("receipt"));
        }
    }

    #[test]
    fn receipt_shape_is_exact_lowercase_hex() {
        assert!(valid_receipt("0123456789abcdef0123456789abcdef"));
        assert!(!valid_receipt("0123456789ABCDEF0123456789ABCDEF"));
        assert!(!valid_receipt("0123456789abcdef0123456789abcdeg"));
    }
}
