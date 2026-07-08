use dory_pb::agent::{ExecRequest, ExecResponse};
use thiserror::Error;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const MAX_TIMEOUT_MS: u64 = 10 * 60_000;
const DEFAULT_OUTPUT_LIMIT: usize = 1024 * 1024;
const MAX_OUTPUT_LIMIT: usize = 16 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum ExecError {
    #[error("exec argv is empty")]
    EmptyArgv,
    #[error("exec argv contains an empty program")]
    EmptyProgram,
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("exec reader failed: {0}")]
    Join(String),
}

impl ExecError {
    pub fn code(&self) -> i32 {
        match self {
            ExecError::EmptyArgv | ExecError::EmptyProgram => 400,
            ExecError::Io(_) | ExecError::Join(_) => 500,
        }
    }
}

pub async fn run(req: ExecRequest) -> Result<ExecResponse, ExecError> {
    let program = req.argv.first().ok_or(ExecError::EmptyArgv)?;
    if program.is_empty() {
        return Err(ExecError::EmptyProgram);
    }

    let mut command = Command::new(program);
    command.args(req.argv.iter().skip(1));
    if !req.cwd.is_empty() {
        command.current_dir(&req.cwd);
    }
    for item in req.env {
        if !item.key.is_empty() {
            command.env(item.key, item.value);
        }
    }
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());

    let _wait_guard = crate::reaper::managed_child_wait_guard().await;
    let mut child = command.spawn()?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let limit = output_limit(req.output_limit_bytes);
    let stdout_task = tokio::spawn(async move {
        match stdout {
            Some(stream) => read_limited(stream, limit).await,
            None => Ok((Vec::new(), false)),
        }
    });
    let stderr_task = tokio::spawn(async move {
        match stderr {
            Some(stream) => read_limited(stream, limit).await,
            None => Ok((Vec::new(), false)),
        }
    });

    let timeout = std::time::Duration::from_millis(timeout_ms(req.timeout_ms));
    let mut timed_out = false;
    let status = match tokio::time::timeout(timeout, child.wait()).await {
        Ok(status) => status?,
        Err(_) => {
            timed_out = true;
            let _ = child.start_kill();
            child.wait().await?
        }
    };

    let (stdout, stdout_truncated) = stdout_task
        .await
        .map_err(|e| ExecError::Join(e.to_string()))??;
    let (stderr, stderr_truncated) = stderr_task
        .await
        .map_err(|e| ExecError::Join(e.to_string()))??;

    Ok(ExecResponse {
        exit_code: status.code().unwrap_or(if timed_out { 124 } else { 128 }),
        stdout,
        stderr,
        timed_out,
        stdout_truncated,
        stderr_truncated,
    })
}

fn timeout_ms(raw: u64) -> u64 {
    match raw {
        0 => DEFAULT_TIMEOUT_MS,
        value => value.min(MAX_TIMEOUT_MS),
    }
}

fn output_limit(raw: u64) -> usize {
    match raw {
        0 => DEFAULT_OUTPUT_LIMIT,
        value => (value as usize).min(MAX_OUTPUT_LIMIT),
    }
}

async fn read_limited<R>(mut reader: R, limit: usize) -> std::io::Result<(Vec<u8>, bool)>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut output = Vec::new();
    let mut truncated = false;
    let mut buffer = [0_u8; 8192];
    loop {
        let n = reader.read(&mut buffer).await?;
        if n == 0 {
            break;
        }
        let remaining = limit.saturating_sub(output.len());
        if remaining > 0 {
            output.extend_from_slice(&buffer[..n.min(remaining)]);
        }
        if n > remaining {
            truncated = true;
        }
    }
    Ok((output, truncated))
}

#[cfg(test)]
mod tests {
    use super::*;
    use dory_pb::agent::ExecEnv;

    #[tokio::test]
    async fn exec_returns_stdout_stderr_and_exit_code() {
        let out = run(ExecRequest {
            argv: vec![
                "/bin/sh".into(),
                "-lc".into(),
                "printf hello; printf err >&2; exit 7".into(),
            ],
            cwd: String::new(),
            env: Vec::new(),
            timeout_ms: 5_000,
            output_limit_bytes: 1024,
        })
        .await
        .unwrap();

        assert_eq!(out.exit_code, 7);
        assert_eq!(out.stdout, b"hello");
        assert_eq!(out.stderr, b"err");
        assert!(!out.timed_out);
    }

    #[tokio::test]
    async fn exec_applies_cwd_env_and_output_limit() {
        let dir = std::env::temp_dir();
        let out = run(ExecRequest {
            argv: vec![
                "/bin/sh".into(),
                "-lc".into(),
                "pwd; printf %s \"$DORY_X\"".into(),
            ],
            cwd: dir.to_string_lossy().into_owned(),
            env: vec![ExecEnv {
                key: "DORY_X".into(),
                value: "abcdef".into(),
            }],
            timeout_ms: 5_000,
            output_limit_bytes: 4,
        })
        .await
        .unwrap();

        assert_eq!(out.stdout.len(), 4);
        assert!(out.stdout_truncated);
    }

    #[tokio::test]
    async fn exec_times_out_and_kills_child() {
        let out = run(ExecRequest {
            argv: vec!["/bin/sh".into(), "-lc".into(), "sleep 5".into()],
            cwd: String::new(),
            env: Vec::new(),
            timeout_ms: 50,
            output_limit_bytes: 1024,
        })
        .await
        .unwrap();

        assert!(out.timed_out);
        assert_eq!(out.exit_code, 124);
    }
}
