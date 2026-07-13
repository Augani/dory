use serde_json::{json, Value};
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const FEX_BUNDLE_PATH: &str = "/usr/lib/dory/fex";
pub const FEX_RUNTIME_PATH: &str = "/run/dory-fex";
pub const FEX_SERVER_SOCKET_PATH: &str = "/run/dory-fex/FEXServer.Socket";

const DEFAULT_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const FORCED_ENVIRONMENT: [(&str, &str); 5] = [
    ("FEX_ROOTFS", "/"),
    ("FEX_NEEDSSECCOMP", "1"),
    ("FEX_APP_DATA_LOCATION", "/tmp/.dory-fex"),
    ("FEX_APP_CONFIG_LOCATION", FEX_BUNDLE_PATH),
    ("FEX_SERVERSOCKETPATH", FEX_SERVER_SOCKET_PATH),
];

#[derive(Debug)]
pub enum WrapperError {
    InvalidArguments(String),
    InvalidSpec(String),
    Io { context: String, source: io::Error },
    Json(serde_json::Error),
}

impl fmt::Display for WrapperError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidArguments(message) | Self::InvalidSpec(message) => {
                formatter.write_str(message)
            }
            Self::Io { context, source } => write!(formatter, "{context}: {source}"),
            Self::Json(error) => write!(formatter, "invalid OCI config JSON: {error}"),
        }
    }
}

impl std::error::Error for WrapperError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Json(error) => Some(error),
            Self::InvalidArguments(_) | Self::InvalidSpec(_) => None,
        }
    }
}

impl From<serde_json::Error> for WrapperError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

fn io_error(context: impl Into<String>, source: io::Error) -> WrapperError {
    WrapperError::Io {
        context: context.into(),
        source,
    }
}

/// Finds an OCI bundle only for runc operations that consume `config.json`. All other runc
/// commands are delegated byte-for-byte without touching the bundle.
pub fn bundle_for_args(
    arguments: &[OsString],
    current_directory: &Path,
) -> Result<Option<PathBuf>, WrapperError> {
    let Some((command_index, command)) = runc_command(arguments) else {
        return Ok(None);
    };
    if !matches!(command, "create" | "run" | "restore") {
        return Ok(None);
    }

    let mut index = command_index + 1;
    while index < arguments.len() {
        let argument = &arguments[index];
        if argument == "--bundle" || argument == "-b" {
            let value = arguments.get(index + 1).ok_or_else(|| {
                WrapperError::InvalidArguments(format!(
                    "{} requires an OCI bundle path",
                    argument.to_string_lossy()
                ))
            })?;
            return Ok(Some(resolve_bundle(value, current_directory)));
        }
        if let Some(argument) = argument.to_str() {
            if let Some(value) = argument
                .strip_prefix("--bundle=")
                .or_else(|| argument.strip_prefix("-b="))
            {
                if value.is_empty() {
                    return Err(WrapperError::InvalidArguments(
                        "runc bundle path cannot be empty".to_owned(),
                    ));
                }
                return Ok(Some(resolve_bundle(value, current_directory)));
            }
        }
        index += 1;
    }

    Ok(Some(current_directory.to_path_buf()))
}

fn runc_command(arguments: &[OsString]) -> Option<(usize, &str)> {
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].to_str()?;
        if argument == "--" {
            let command_index = index + 1;
            return arguments
                .get(command_index)
                .and_then(|command| command.to_str())
                .map(|command| (command_index, command));
        }
        if argument.starts_with('-') {
            let takes_separate_value = matches!(
                argument,
                "--root" | "--log" | "--log-format" | "--rootless" | "--criu"
            );
            index += if takes_separate_value { 2 } else { 1 };
            continue;
        }
        return Some((index, argument));
    }
    None
}

fn runc_log_path(arguments: &[OsString], current_directory: &Path) -> Option<PathBuf> {
    let mut index = 0;
    while index < arguments.len() {
        let argument = arguments[index].to_str()?;
        if argument == "--log" {
            return arguments
                .get(index + 1)
                .map(|value| resolve_bundle(value, current_directory));
        }
        if let Some(value) = argument.strip_prefix("--log=") {
            return (!value.is_empty()).then(|| resolve_bundle(value, current_directory));
        }
        if !argument.starts_with('-') {
            break;
        }
        let takes_separate_value = matches!(
            argument,
            "--root" | "--log-format" | "--rootless" | "--criu"
        );
        index += if takes_separate_value { 2 } else { 1 };
    }
    None
}

/// runc's caller supplies a JSON log path before `create`. If Dory rejects the OCI spec before
/// delegating, write the same error surface so containerd/Docker can return the actionable reason.
pub fn record_runc_error(
    arguments: &[OsString],
    current_directory: &Path,
    message: &str,
) -> Result<bool, WrapperError> {
    let Some(log_path) = runc_log_path(arguments, current_directory) else {
        return Ok(false);
    };
    let mut log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&log_path)
        .map_err(|error| {
            io_error(
                format!("cannot open runc log {}", log_path.display()),
                error,
            )
        })?;
    let mut entry = serde_json::to_vec(&json!({
        "level": "error",
        "msg": message,
        "source": "dory-runc"
    }))?;
    entry.push(b'\n');
    log.write_all(&entry).map_err(|error| {
        io_error(
            format!("cannot write runc log {}", log_path.display()),
            error,
        )
    })?;
    log.sync_data().map_err(|error| {
        io_error(
            format!("cannot sync runc log {}", log_path.display()),
            error,
        )
    })?;
    Ok(true)
}

fn resolve_bundle(value: impl AsRef<std::ffi::OsStr>, current_directory: &Path) -> PathBuf {
    let path = PathBuf::from(value.as_ref());
    if path.is_absolute() {
        path
    } else {
        current_directory.join(path)
    }
}

/// Adds Dory's private FEX bundle, container-private server runtime, and fail-closed environment
/// contract to an OCI spec. The reserved mounts are safe in native ARM containers and make later
/// `docker exec` of an x86-64 binary work without knowing the image architecture at create time.
pub fn inject_fex(spec: &mut Value) -> Result<bool, WrapperError> {
    let root = spec.as_object_mut().ok_or_else(|| {
        WrapperError::InvalidSpec("OCI config root must be a JSON object".to_owned())
    })?;
    let mut changed = false;

    let mounts = root
        .entry("mounts")
        .or_insert_with(|| Value::Array(Vec::new()));
    let mounts = mounts.as_array_mut().ok_or_else(|| {
        WrapperError::InvalidSpec("OCI config mounts must be an array".to_owned())
    })?;
    let mut has_expected_bundle_mount = false;
    let mut has_expected_runtime_mount = false;
    for mount in mounts.iter() {
        let Some(mount) = mount.as_object() else {
            return Err(WrapperError::InvalidSpec(
                "OCI config contains a non-object mount".to_owned(),
            ));
        };
        let Some(destination) = mount.get("destination").and_then(Value::as_str) else {
            return Err(WrapperError::InvalidSpec(
                "OCI mount is missing a string destination".to_owned(),
            ));
        };
        match normalized_destination(destination) {
            FEX_BUNDLE_PATH => {
                if is_expected_bundle_mount(mount) {
                    has_expected_bundle_mount = true;
                } else {
                    return Err(WrapperError::InvalidSpec(format!(
                        "OCI mount destination {FEX_BUNDLE_PATH} is reserved by Dory's amd64 runtime"
                    )));
                }
            }
            FEX_RUNTIME_PATH => {
                if is_expected_runtime_mount(mount) {
                    has_expected_runtime_mount = true;
                } else {
                    return Err(WrapperError::InvalidSpec(format!(
                        "OCI mount destination {FEX_RUNTIME_PATH} is reserved by Dory's amd64 runtime"
                    )));
                }
            }
            _ => continue,
        }
    }
    if !has_expected_bundle_mount {
        mounts.push(json!({
            "destination": FEX_BUNDLE_PATH,
            "type": "bind",
            "source": FEX_BUNDLE_PATH,
            "options": ["rbind", "ro", "nosuid", "nodev"]
        }));
        changed = true;
    }
    if !has_expected_runtime_mount {
        mounts.push(json!({
            "destination": FEX_RUNTIME_PATH,
            "type": "tmpfs",
            "source": "tmpfs",
            "options": ["nosuid", "nodev", "noexec", "mode=1777", "size=1m"]
        }));
        changed = true;
    }

    let process = root
        .get_mut("process")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| {
            WrapperError::InvalidSpec("OCI config process must be an object".to_owned())
        })?;
    let environment = process
        .entry("env")
        .or_insert_with(|| Value::Array(Vec::new()));
    let environment = environment
        .as_array_mut()
        .ok_or_else(|| WrapperError::InvalidSpec("OCI process env must be an array".to_owned()))?;
    let original_environment = std::mem::take(environment);
    let mut existing_path: Option<String> = None;
    let mut retained =
        Vec::with_capacity(original_environment.len() + FORCED_ENVIRONMENT.len() + 1);
    for entry in &original_environment {
        let Some(entry) = entry.as_str() else {
            return Err(WrapperError::InvalidSpec(
                "OCI process env contains a non-string value".to_owned(),
            ));
        };
        let (name, value) = entry.split_once('=').unwrap_or((entry, ""));
        if name == "PATH" {
            existing_path = Some(value.to_owned());
            continue;
        }
        if FORCED_ENVIRONMENT.iter().any(|(forced, _)| name == *forced) {
            continue;
        }
        retained.push(Value::String(entry.to_owned()));
    }

    let path = fex_path(existing_path.as_deref().unwrap_or(DEFAULT_PATH));
    retained.push(Value::String(format!("PATH={path}")));
    for (name, value) in FORCED_ENVIRONMENT {
        retained.push(Value::String(format!("{name}={value}")));
    }
    if original_environment != retained {
        *environment = retained;
        changed = true;
    } else {
        *environment = original_environment;
    }

    Ok(changed)
}

fn normalized_destination(destination: &str) -> &str {
    if destination == "/" {
        destination
    } else {
        destination.trim_end_matches('/')
    }
}

fn is_expected_bundle_mount(mount: &serde_json::Map<String, Value>) -> bool {
    mount.get("source").and_then(Value::as_str) == Some(FEX_BUNDLE_PATH)
        && mount.get("type").and_then(Value::as_str) == Some("bind")
        && mount
            .get("options")
            .and_then(Value::as_array)
            .is_some_and(|options| {
                options
                    == &[
                        Value::String("rbind".to_owned()),
                        Value::String("ro".to_owned()),
                        Value::String("nosuid".to_owned()),
                        Value::String("nodev".to_owned()),
                    ]
            })
}

fn is_expected_runtime_mount(mount: &serde_json::Map<String, Value>) -> bool {
    mount.get("source").and_then(Value::as_str) == Some("tmpfs")
        && mount.get("type").and_then(Value::as_str) == Some("tmpfs")
        && mount
            .get("options")
            .and_then(Value::as_array)
            .is_some_and(|options| {
                options
                    == &[
                        Value::String("nosuid".to_owned()),
                        Value::String("nodev".to_owned()),
                        Value::String("noexec".to_owned()),
                        Value::String("mode=1777".to_owned()),
                        Value::String("size=1m".to_owned()),
                    ]
            })
}

fn fex_path(existing: &str) -> String {
    let suffix = existing
        .split(':')
        .filter(|component| *component != FEX_BUNDLE_PATH)
        .collect::<Vec<_>>()
        .join(":");
    if suffix.is_empty() {
        FEX_BUNDLE_PATH.to_owned()
    } else {
        format!("{FEX_BUNDLE_PATH}:{suffix}")
    }
}

pub fn prepare_bundle(bundle: &Path) -> Result<bool, WrapperError> {
    let config_path = bundle.join("config.json");
    let metadata = fs::symlink_metadata(&config_path)
        .map_err(|error| io_error(format!("cannot inspect {}", config_path.display()), error))?;
    if !metadata.file_type().is_file() {
        return Err(WrapperError::InvalidSpec(format!(
            "{} is not a regular OCI config file",
            config_path.display()
        )));
    }
    let original = fs::read(&config_path)
        .map_err(|error| io_error(format!("cannot read {}", config_path.display()), error))?;
    let mut spec: Value = serde_json::from_slice(&original)?;
    if !inject_fex(&mut spec)? {
        return Ok(false);
    }
    let mut encoded = serde_json::to_vec(&spec)?;
    encoded.push(b'\n');
    atomic_replace(&config_path, &encoded, metadata.permissions().mode())?;
    Ok(true)
}

pub fn prepare_for_args(
    arguments: &[OsString],
    current_directory: &Path,
) -> Result<bool, WrapperError> {
    let Some(bundle) = bundle_for_args(arguments, current_directory)? else {
        return Ok(false);
    };
    prepare_bundle(&bundle)
}

fn atomic_replace(path: &Path, contents: &[u8], mode: u32) -> Result<(), WrapperError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("config.json");
    let mut temporary_path = None;
    let mut temporary_file = None;
    for attempt in 0..100_u32 {
        let candidate = parent.join(format!(
            ".{file_name}.dory-{}-{attempt}",
            std::process::id()
        ));
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => {
                temporary_path = Some(candidate);
                temporary_file = Some(file);
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(io_error(
                    format!(
                        "cannot create temporary OCI config beside {}",
                        path.display()
                    ),
                    error,
                ));
            }
        }
    }
    let temporary_path = temporary_path.ok_or_else(|| {
        WrapperError::InvalidSpec(format!(
            "could not allocate a temporary OCI config beside {}",
            path.display()
        ))
    })?;
    let mut temporary_file = temporary_file.expect("temporary path and file are set together");

    let write_result = (|| {
        temporary_file
            .set_permissions(fs::Permissions::from_mode(mode))
            .map_err(|error| io_error("cannot preserve OCI config permissions", error))?;
        temporary_file
            .write_all(contents)
            .map_err(|error| io_error("cannot write temporary OCI config", error))?;
        temporary_file
            .sync_all()
            .map_err(|error| io_error("cannot sync temporary OCI config", error))?;
        drop(temporary_file);
        fs::rename(&temporary_path, path)
            .map_err(|error| io_error(format!("cannot replace {}", path.display()), error))?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| io_error("cannot sync OCI bundle directory", error))?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary_path);
    }
    write_result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn spec(environment: &[&str]) -> Value {
        json!({
            "ociVersion": "1.2.0",
            "process": {
                "args": ["/bin/sh"],
                "env": environment,
                "cwd": "/"
            },
            "root": { "path": "rootfs" },
            "mounts": []
        })
    }

    fn environment(spec: &Value) -> Vec<&str> {
        spec["process"]["env"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry.as_str().unwrap())
            .collect()
    }

    fn temporary_directory(label: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "dory-runc-wrapper-{label}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&path).unwrap();
        path
    }

    #[test]
    fn injects_reserved_bundle_and_private_runtime_mounts_idempotently() {
        let mut value = spec(&["PATH=/bin", "HOME=/root"]);
        assert!(inject_fex(&mut value).unwrap());
        assert!(!inject_fex(&mut value).unwrap());

        assert_eq!(value["mounts"].as_array().unwrap().len(), 2);
        assert_eq!(value["mounts"][0]["source"], FEX_BUNDLE_PATH);
        assert_eq!(value["mounts"][0]["destination"], FEX_BUNDLE_PATH);
        assert_eq!(
            value["mounts"][0]["options"],
            json!(["rbind", "ro", "nosuid", "nodev"])
        );
        assert_eq!(value["mounts"][1]["source"], "tmpfs");
        assert_eq!(value["mounts"][1]["destination"], FEX_RUNTIME_PATH);
        assert_eq!(value["mounts"][1]["type"], "tmpfs");
        assert_eq!(
            value["mounts"][1]["options"],
            json!(["nosuid", "nodev", "noexec", "mode=1777", "size=1m"])
        );
    }

    #[test]
    fn rejects_a_user_mount_at_the_reserved_destination() {
        let mut value = spec(&[]);
        value["mounts"] = json!([{
            "destination": "/usr/lib/dory/fex/",
            "type": "bind",
            "source": "/tmp/user-content",
            "options": ["rbind", "rw"]
        }]);

        let error = inject_fex(&mut value).unwrap_err().to_string();
        assert!(error.contains("reserved by Dory"));
    }

    #[test]
    fn rejects_a_user_mount_at_the_private_runtime_destination() {
        let mut value = spec(&[]);
        value["mounts"] = json!([{
            "destination": "/run/dory-fex/",
            "type": "bind",
            "source": "/tmp/user-content",
            "options": ["rbind", "rw"]
        }]);

        let error = inject_fex(&mut value).unwrap_err().to_string();
        assert!(error.contains(FEX_RUNTIME_PATH));
        assert!(error.contains("reserved by Dory"));
    }

    #[test]
    fn forces_seccomp_contract_and_prepends_path_without_duplicates() {
        let mut value = spec(&[
            "HOME=/root",
            "FEX_ROOTFS=/unsafe",
            "FEX_NEEDSSECCOMP=0",
            "FEX_APP_DATA_LOCATION=/root/.fex",
            "FEX_APP_CONFIG_LOCATION=/hostile/config",
            "FEX_SERVERSOCKETPATH=/hostile/socket",
            "PATH=/bin:/usr/lib/dory/fex:/usr/bin",
        ]);
        inject_fex(&mut value).unwrap();

        assert_eq!(
            environment(&value),
            vec![
                "HOME=/root",
                "PATH=/usr/lib/dory/fex:/bin:/usr/bin",
                "FEX_ROOTFS=/",
                "FEX_NEEDSSECCOMP=1",
                "FEX_APP_DATA_LOCATION=/tmp/.dory-fex",
                "FEX_APP_CONFIG_LOCATION=/usr/lib/dory/fex",
                "FEX_SERVERSOCKETPATH=/run/dory-fex/FEXServer.Socket",
            ]
        );
    }

    #[test]
    fn parses_all_runc_bundle_forms_and_defaults_to_cwd() {
        let cwd = Path::new("/run/dory-test");
        for arguments in [
            vec![
                OsString::from("create"),
                OsString::from("--bundle"),
                OsString::from("one"),
            ],
            vec![OsString::from("run"), OsString::from("--bundle=two")],
            vec![
                OsString::from("restore"),
                OsString::from("-b"),
                OsString::from("three"),
            ],
            vec![OsString::from("create"), OsString::from("-b=four")],
        ] {
            assert!(bundle_for_args(&arguments, cwd)
                .unwrap()
                .unwrap()
                .starts_with(cwd));
        }
        assert_eq!(
            bundle_for_args(&[OsString::from("create")], cwd).unwrap(),
            Some(cwd.to_path_buf())
        );
        assert_eq!(
            bundle_for_args(&[OsString::from("exec")], cwd).unwrap(),
            None
        );
        assert_eq!(
            bundle_for_args(
                &[
                    OsString::from("--root"),
                    OsString::from("create"),
                    OsString::from("delete"),
                    OsString::from("create"),
                ],
                cwd,
            )
            .unwrap(),
            None
        );
    }

    #[test]
    fn atomically_rewrites_once_and_preserves_mode() {
        let directory = temporary_directory("atomic");
        let config = directory.join("config.json");
        fs::write(&config, serde_json::to_vec(&spec(&[])).unwrap()).unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o640)).unwrap();

        assert!(prepare_bundle(&directory).unwrap());
        let first = fs::read(&config).unwrap();
        assert!(!prepare_bundle(&directory).unwrap());
        assert_eq!(fs::read(&config).unwrap(), first);
        assert_eq!(
            fs::metadata(&config).unwrap().permissions().mode() & 0o777,
            0o640
        );

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn records_pre_runc_rejections_in_the_requested_json_log() {
        let directory = temporary_directory("runc-log");
        let log_path = directory.join("runc.json");
        let arguments = vec![
            OsString::from("--log"),
            log_path.clone().into_os_string(),
            OsString::from("create"),
        ];

        assert!(record_runc_error(&arguments, &directory, "reserved mount").unwrap());
        let line = fs::read_to_string(&log_path).unwrap();
        let value: Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(value["msg"], "reserved mount");
        assert_eq!(value["source"], "dory-runc");

        fs::remove_dir_all(directory).unwrap();
    }
}
