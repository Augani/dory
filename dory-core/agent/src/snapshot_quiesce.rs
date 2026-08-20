use std::path::Path;
use std::time::Duration;

use dory_pb::agent::{
    snapshot_quiesce_request::Action, SnapshotQuiesceRequest, SnapshotQuiesceResponse,
};

const QUIESCE_TIMEOUT: Duration = Duration::from_secs(20);

pub fn available() -> bool {
    binary().is_some()
}

pub async fn run(request: SnapshotQuiesceRequest) -> SnapshotQuiesceResponse {
    let action = match Action::try_from(request.action) {
        Ok(Action::Freeze) => "-f",
        Ok(Action::Thaw) => "-u",
        _ => return response(false, "snapshot quiesce action is invalid"),
    };
    let Some(binary) = binary() else {
        return response(false, "filesystem freeze is unavailable in this guest");
    };

    let mut command = tokio::process::Command::new(binary);
    command.args([action, "/"]).kill_on_drop(true);
    match tokio::time::timeout(QUIESCE_TIMEOUT, command.output()).await {
        Ok(Ok(output)) if output.status.success() => response(true, ""),
        Ok(Ok(output)) => {
            let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
            response(
                false,
                if detail.is_empty() {
                    "filesystem freeze command failed"
                } else {
                    detail.as_str()
                },
            )
        }
        Ok(Err(error)) => response(false, &format!("filesystem freeze command failed: {error}")),
        Err(_) => response(false, "filesystem freeze command timed out"),
    }
}

fn response(completed: bool, detail: &str) -> SnapshotQuiesceResponse {
    SnapshotQuiesceResponse {
        completed,
        detail: detail.chars().take(512).collect(),
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
        })
        .await;
        assert!(!result.completed);
        assert!(result.detail.contains("invalid"));
    }
}
