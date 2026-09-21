use dory_pb::agent::{self, clipboard_request::Action, ExecRequest};
use thiserror::Error;

use crate::exec;

pub const CAPABILITY_ID: &str = "clipboard";
pub const CAPABILITY_VERSION: u32 = 1;
pub const MAXIMUM_PAYLOAD_BYTES: usize = 15 * 1024 * 1024;

const HELPER_PATH: &str = "/usr/lib/dory/clipboard";
const HELPER_TIMEOUT_MS: u64 = 5_000;
const DIAGNOSTIC_LIMIT_BYTES: u64 = 64 * 1024;
const ALLOWED_MIME_TYPES: [&str; 3] = ["text/plain", "text/plain;charset=utf-8", "image/png"];

#[derive(Debug, Error)]
pub enum ClipboardError {
    #[error("clipboard action is required")]
    MissingAction,
    #[error("unsupported clipboard MIME type")]
    UnsupportedMimeType,
    #[error("clipboard payload exceeds {MAXIMUM_PAYLOAD_BYTES} bytes")]
    PayloadTooLarge,
    #[error("clipboard payload is not valid for this action")]
    UnexpectedPayload,
    #[error("Dory clipboard helper is unavailable")]
    HelperUnavailable,
    #[error("clipboard helper timed out")]
    TimedOut,
    #[error("clipboard helper output exceeded its bound")]
    OutputTruncated,
    #[error("clipboard backend failed: {0}")]
    Backend(String),
    #[error("clipboard helper could not execute: {0}")]
    Exec(#[from] exec::ExecError),
}

impl ClipboardError {
    pub fn code(&self) -> i32 {
        match self {
            Self::MissingAction
            | Self::UnsupportedMimeType
            | Self::PayloadTooLarge
            | Self::UnexpectedPayload => 422,
            Self::HelperUnavailable => 503,
            Self::TimedOut | Self::OutputTruncated | Self::Backend(_) => 502,
            Self::Exec(error) => error.code(),
        }
    }
}

pub fn available() -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(HELPER_PATH)
            .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        false
    }
}

pub async fn run(
    request: agent::ClipboardRequest,
) -> Result<agent::ClipboardResponse, ClipboardError> {
    let action = validate(&request)?;
    if !available() {
        return Err(ClipboardError::HelperUnavailable);
    }

    let (operation, output_limit_bytes) = match action {
        Action::Get => ("get", MAXIMUM_PAYLOAD_BYTES as u64),
        Action::Set => ("set", DIAGNOSTIC_LIMIT_BYTES),
        Action::ListTypes => ("types", DIAGNOSTIC_LIMIT_BYTES),
        Action::Unspecified => unreachable!("validation rejects unspecified actions"),
    };
    let mut argv = vec![HELPER_PATH.to_string(), operation.to_string()];
    if action != Action::ListTypes {
        argv.push(request.mime_type.clone());
    }
    let result = exec::run(ExecRequest {
        argv,
        cwd: String::new(),
        env: Vec::new(),
        timeout_ms: HELPER_TIMEOUT_MS,
        output_limit_bytes,
        stdin: request.data,
    })
    .await?;
    if result.timed_out {
        return Err(ClipboardError::TimedOut);
    }
    if result.stdout_truncated || result.stderr_truncated {
        return Err(ClipboardError::OutputTruncated);
    }
    if result.exit_code != 0 {
        let detail = String::from_utf8_lossy(&result.stderr).trim().to_string();
        return Err(ClipboardError::Backend(if detail.is_empty() {
            format!("exit {}", result.exit_code)
        } else {
            detail
        }));
    }

    let mut response = agent::ClipboardResponse::default();
    match action {
        Action::Get => {
            response.mime_type = request.mime_type;
            response.data = result.stdout;
        }
        Action::Set => response.mime_type = request.mime_type,
        Action::ListTypes => {
            response.mime_types = String::from_utf8_lossy(&result.stdout)
                .lines()
                .map(str::trim)
                .filter(|mime| is_allowed_mime_type(mime))
                .map(str::to_string)
                .collect();
            response.mime_types.sort_unstable();
            response.mime_types.dedup();
        }
        Action::Unspecified => unreachable!("validation rejects unspecified actions"),
    }
    Ok(response)
}

fn validate(request: &agent::ClipboardRequest) -> Result<Action, ClipboardError> {
    let action = Action::try_from(request.action).map_err(|_| ClipboardError::MissingAction)?;
    match action {
        Action::Unspecified => return Err(ClipboardError::MissingAction),
        Action::Get => {
            if !request.data.is_empty() {
                return Err(ClipboardError::UnexpectedPayload);
            }
        }
        Action::Set => {
            if request.data.len() > MAXIMUM_PAYLOAD_BYTES {
                return Err(ClipboardError::PayloadTooLarge);
            }
        }
        Action::ListTypes => {
            if !request.mime_type.is_empty() || !request.data.is_empty() {
                return Err(ClipboardError::UnexpectedPayload);
            }
            return Ok(action);
        }
    }
    if !is_allowed_mime_type(&request.mime_type) {
        return Err(ClipboardError::UnsupportedMimeType);
    }
    Ok(action)
}

fn is_allowed_mime_type(mime_type: &str) -> bool {
    ALLOWED_MIME_TYPES.contains(&mime_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(action: Action, mime_type: &str, data: Vec<u8>) -> agent::ClipboardRequest {
        agent::ClipboardRequest {
            action: action as i32,
            mime_type: mime_type.into(),
            data,
        }
    }

    #[test]
    fn accepts_only_the_declared_mime_types() {
        for mime_type in ALLOWED_MIME_TYPES {
            assert_eq!(
                validate(&request(Action::Get, mime_type, Vec::new())).unwrap(),
                Action::Get
            );
        }
        assert!(matches!(
            validate(&request(Action::Get, "text/html", Vec::new())),
            Err(ClipboardError::UnsupportedMimeType)
        ));
    }

    #[test]
    fn bounds_set_payload_before_platform_io() {
        assert_eq!(
            validate(&request(
                Action::Set,
                "image/png",
                vec![0; MAXIMUM_PAYLOAD_BYTES]
            ))
            .unwrap(),
            Action::Set
        );
        assert!(matches!(
            validate(&request(
                Action::Set,
                "image/png",
                vec![0; MAXIMUM_PAYLOAD_BYTES + 1]
            )),
            Err(ClipboardError::PayloadTooLarge)
        ));
    }

    #[test]
    fn rejects_action_confusion_before_platform_io() {
        assert!(matches!(
            validate(&request(Action::Get, "text/plain", b"unexpected".to_vec())),
            Err(ClipboardError::UnexpectedPayload)
        ));
        assert!(matches!(
            validate(&request(Action::ListTypes, "text/plain", Vec::new())),
            Err(ClipboardError::UnexpectedPayload)
        ));
        assert!(matches!(
            validate(&request(Action::Unspecified, "", Vec::new())),
            Err(ClipboardError::MissingAction)
        ));
    }
}
