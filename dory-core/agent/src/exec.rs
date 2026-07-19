use dory_pb::agent::{ExecRequest, ExecResponse};
use std::collections::HashMap;
use thiserror::Error;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const MAX_TIMEOUT_MS: u64 = 10 * 60_000;
const DEFAULT_OUTPUT_LIMIT: usize = 1024 * 1024;
const MAX_OUTPUT_LIMIT: usize = 16 * 1024 * 1024;
// After the child is reaped, any bytes still in the pipes are bounded by the kernel buffer — unless
// a descendant inherited the write end. Bound the drain so such a descendant can never hang the RPC.
const DRAIN_TIMEOUT_MS: u64 = 5_000;

// These control keys are consumed by the guest agent and are deliberately never inherited by the
// child. Keeping them in the existing exec envelope preserves protocol compatibility while giving
// sandbox callers a least-privilege execution primitive. Ordinary machine exec remains unchanged.
const RUN_UID_KEY: &str = "DORY_AGENT_RUN_UID";
const RUN_GID_KEY: &str = "DORY_AGENT_RUN_GID";
const MAX_PROCESSES_KEY: &str = "DORY_AGENT_MAX_PROCESSES";
const MAX_FILE_BYTES_KEY: &str = "DORY_AGENT_MAX_FILE_BYTES";
const MAX_OPEN_FILES_KEY: &str = "DORY_AGENT_MAX_OPEN_FILES";

#[derive(Debug, Error)]
pub enum ExecError {
    #[error("exec argv is empty")]
    EmptyArgv,
    #[error("exec argv contains an empty program")]
    EmptyProgram,
    #[error("invalid exec constraint: {0}")]
    InvalidConstraint(String),
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("exec reader failed: {0}")]
    Join(String),
}

impl ExecError {
    pub fn code(&self) -> i32 {
        match self {
            ExecError::EmptyArgv | ExecError::EmptyProgram | ExecError::InvalidConstraint(_) => 400,
            ExecError::Io(_) | ExecError::Join(_) => 500,
        }
    }
}

pub async fn run(req: ExecRequest) -> Result<ExecResponse, ExecError> {
    let program = req.argv.first().ok_or(ExecError::EmptyArgv)?;
    if program.is_empty() {
        return Err(ExecError::EmptyProgram);
    }

    let (environment, constraints) = parse_environment_and_constraints(req.env)?;
    let mut command = Command::new(program);
    command.args(req.argv.iter().skip(1));
    if !req.cwd.is_empty() {
        command.current_dir(&req.cwd);
    }
    for item in environment {
        if !item.key.is_empty() {
            command.env(item.key, item.value);
        }
    }
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());
    // Own process group so a timeout can kill the whole tree, not just the direct child — a
    // backgrounded descendant would otherwise survive the kill and hold the output pipes open.
    #[cfg(unix)]
    command.process_group(0);
    apply_constraints(&mut command, constraints)?;

    let _wait_guard = crate::reaper::managed_child_wait_guard().await;
    let mut child = command.spawn()?;
    let group_pid = child.id();
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
            kill_process_group(group_pid);
            let _ = child.start_kill();
            child.wait().await?
        }
    };

    let (stdout, stdout_truncated) = drain_output(stdout_task, group_pid).await?;
    let (stderr, stderr_truncated) = drain_output(stderr_task, group_pid).await?;

    Ok(ExecResponse {
        exit_code: status.code().unwrap_or(if timed_out { 124 } else { 128 }),
        stdout,
        stderr,
        timed_out,
        stdout_truncated,
        stderr_truncated,
    })
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct ExecConstraints {
    uid: Option<u32>,
    gid: Option<u32>,
    max_processes: Option<u64>,
    max_file_bytes: Option<u64>,
    max_open_files: Option<u64>,
}

fn parse_environment_and_constraints(
    environment: Vec<dory_pb::agent::ExecEnv>,
) -> Result<(Vec<dory_pb::agent::ExecEnv>, ExecConstraints), ExecError> {
    let mut child_environment = Vec::with_capacity(environment.len());
    let mut control = HashMap::new();
    for item in environment {
        if [
            RUN_UID_KEY,
            RUN_GID_KEY,
            MAX_PROCESSES_KEY,
            MAX_FILE_BYTES_KEY,
            MAX_OPEN_FILES_KEY,
        ]
        .contains(&item.key.as_str())
        {
            control.insert(item.key, item.value);
        } else {
            child_environment.push(item);
        }
    }
    let uid = parse_optional_u32(&control, RUN_UID_KEY)?;
    let gid = parse_optional_u32(&control, RUN_GID_KEY)?;
    if uid.is_some() != gid.is_some() {
        return Err(ExecError::InvalidConstraint(
            "run uid and gid must be supplied together".into(),
        ));
    }
    Ok((
        child_environment,
        ExecConstraints {
            uid,
            gid,
            max_processes: parse_optional_positive_u64(&control, MAX_PROCESSES_KEY)?,
            max_file_bytes: parse_optional_positive_u64(&control, MAX_FILE_BYTES_KEY)?,
            max_open_files: parse_optional_positive_u64(&control, MAX_OPEN_FILES_KEY)?,
        },
    ))
}

fn parse_optional_u32(
    values: &HashMap<String, String>,
    key: &str,
) -> Result<Option<u32>, ExecError> {
    values
        .get(key)
        .map(|raw| {
            raw.parse::<u32>()
                .map_err(|_| ExecError::InvalidConstraint(key.into()))
        })
        .transpose()
}

fn parse_optional_positive_u64(
    values: &HashMap<String, String>,
    key: &str,
) -> Result<Option<u64>, ExecError> {
    values
        .get(key)
        .map(|raw| {
            raw.parse::<u64>()
                .ok()
                .filter(|value| *value > 0)
                .ok_or_else(|| ExecError::InvalidConstraint(key.into()))
        })
        .transpose()
}

#[cfg(unix)]
fn apply_constraints(command: &mut Command, constraints: ExecConstraints) -> Result<(), ExecError> {
    if let (Some(uid), Some(gid)) = (constraints.uid, constraints.gid) {
        command.gid(gid);
        command.uid(uid);
    }
    unsafe {
        command.pre_exec(move || {
            set_limit(libc::RLIMIT_NPROC, constraints.max_processes)?;
            set_limit(libc::RLIMIT_FSIZE, constraints.max_file_bytes)?;
            set_limit(libc::RLIMIT_NOFILE, constraints.max_open_files)?;
            Ok(())
        });
    }
    Ok(())
}

#[cfg(not(unix))]
fn apply_constraints(
    _command: &mut Command,
    constraints: ExecConstraints,
) -> Result<(), ExecError> {
    if constraints != ExecConstraints::default() {
        return Err(ExecError::InvalidConstraint(
            "restricted execution requires a Unix guest".into(),
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
type RlimitResource = libc::__rlimit_resource_t;
#[cfg(all(unix, not(target_os = "linux")))]
type RlimitResource = libc::c_int;

#[cfg(unix)]
fn set_limit(resource: RlimitResource, value: Option<u64>) -> std::io::Result<()> {
    let Some(value) = value else { return Ok(()) };
    let limit = libc::rlimit {
        rlim_cur: value as libc::rlim_t,
        rlim_max: value as libc::rlim_t,
    };
    if unsafe { libc::setrlimit(resource, &limit) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// Await a reader task, but never forever: a descendant holding the pipe write-end keeps the reader
/// from EOF, so on a stalled drain sweep the process group (closing the pipes) and retry once; a
/// survivor that escaped the group forfeits its residual bytes rather than hanging the RPC.
async fn drain_output(
    mut task: tokio::task::JoinHandle<std::io::Result<(Vec<u8>, bool)>>,
    group_pid: Option<u32>,
) -> Result<(Vec<u8>, bool), ExecError> {
    let drain = std::time::Duration::from_millis(DRAIN_TIMEOUT_MS);
    if let Ok(joined) = tokio::time::timeout(drain, &mut task).await {
        return Ok(joined.map_err(|e| ExecError::Join(e.to_string()))??);
    }
    kill_process_group(group_pid);
    match tokio::time::timeout(drain, &mut task).await {
        Ok(joined) => Ok(joined.map_err(|e| ExecError::Join(e.to_string()))??),
        Err(_) => {
            task.abort();
            Ok((Vec::new(), true))
        }
    }
}

fn kill_process_group(group_pid: Option<u32>) {
    #[cfg(unix)]
    if let Some(pid) = group_pid {
        if let Ok(pid) = i32::try_from(pid) {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
    }
    #[cfg(not(unix))]
    let _ = group_pid;
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
    async fn exec_returns_despite_descendant_holding_stdout_open() {
        // The backgrounded sleep inherits the stdout pipe, so the reader never sees EOF from the
        // direct child alone. The bounded drain must sweep the process group and still deliver the
        // bytes the command actually wrote.
        let start = std::time::Instant::now();
        let out = run(ExecRequest {
            argv: vec![
                "/bin/sh".into(),
                "-c".into(),
                "sleep 600 & printf held".into(),
            ],
            cwd: String::new(),
            env: Vec::new(),
            timeout_ms: 60_000,
            output_limit_bytes: 1024,
        })
        .await
        .unwrap();

        assert_eq!(out.exit_code, 0);
        assert_eq!(out.stdout, b"held");
        assert!(!out.timed_out);
        assert!(
            start.elapsed() < std::time::Duration::from_secs(30),
            "drain must be bounded, took {:?}",
            start.elapsed()
        );
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

    #[test]
    fn sandbox_constraints_are_consumed_and_validated() {
        let (environment, constraints) = parse_environment_and_constraints(vec![
            ExecEnv {
                key: RUN_UID_KEY.into(),
                value: "501".into(),
            },
            ExecEnv {
                key: RUN_GID_KEY.into(),
                value: "20".into(),
            },
            ExecEnv {
                key: MAX_PROCESSES_KEY.into(),
                value: "64".into(),
            },
            ExecEnv {
                key: MAX_FILE_BYTES_KEY.into(),
                value: "1048576".into(),
            },
            ExecEnv {
                key: "VISIBLE".into(),
                value: "yes".into(),
            },
        ])
        .unwrap();

        assert_eq!(
            environment,
            vec![ExecEnv {
                key: "VISIBLE".into(),
                value: "yes".into()
            }]
        );
        assert_eq!(constraints.uid, Some(501));
        assert_eq!(constraints.gid, Some(20));
        assert_eq!(constraints.max_processes, Some(64));
        assert_eq!(constraints.max_file_bytes, Some(1_048_576));
    }

    #[test]
    fn sandbox_identity_requires_uid_and_gid_together() {
        let error = parse_environment_and_constraints(vec![ExecEnv {
            key: RUN_UID_KEY.into(),
            value: "501".into(),
        }])
        .unwrap_err();
        assert!(matches!(error, ExecError::InvalidConstraint(_)));
        assert_eq!(error.code(), 400);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn sandbox_constraints_apply_identity_limits_and_do_not_leak_control_environment() {
        let uid = unsafe { libc::getuid() };
        let gid = unsafe { libc::getgid() };
        let out = run(ExecRequest {
            argv: vec![
                "/bin/sh".into(),
                "-c".into(),
                "printf '%s %s %s' \"$(id -u)\" \"$(ulimit -n)\" \"${DORY_AGENT_RUN_UID-unset}\""
                    .into(),
            ],
            cwd: String::new(),
            env: vec![
                ExecEnv {
                    key: RUN_UID_KEY.into(),
                    value: uid.to_string(),
                },
                ExecEnv {
                    key: RUN_GID_KEY.into(),
                    value: gid.to_string(),
                },
                ExecEnv {
                    key: MAX_OPEN_FILES_KEY.into(),
                    value: "64".into(),
                },
            ],
            timeout_ms: 5_000,
            output_limit_bytes: 1_024,
        })
        .await
        .unwrap();

        assert_eq!(out.exit_code, 0);
        assert_eq!(
            String::from_utf8(out.stdout).unwrap(),
            format!("{uid} 64 unset")
        );
    }
}
