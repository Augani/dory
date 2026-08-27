use serde_json::{json, Value};
use std::collections::VecDeque;
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub const FEX_BUNDLE_PATH: &str = "/usr/lib/dory/fex";
pub const FEX_RUNTIME_PATH: &str = "/run/dory-fex";
pub const FEX_SERVER_SOCKET_PATH: &str = "/run/dory-fex/FEXServer.Socket";
pub const FEX_SERVER_PATH: &str = "/usr/lib/dory/fex/FEXServer";
pub const FEX_INIT_PATH: &str = "/run/dory-fex/dory-fex-init";
pub const DORY_RUNC_PATH: &str = "/usr/local/bin/dory-runc";
pub const REAL_RUNC_PATH: &str = "/usr/local/bin/runc.real";

const NESTED_RUNC_CANDIDATES: [&str; 6] = [
    "/usr/local/sbin/runc",
    "/usr/local/bin/runc",
    "/usr/sbin/runc",
    "/usr/bin/runc",
    "/sbin/runc",
    "/bin/runc",
];

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
    let mut has_expected_hook_mount = false;
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
            FEX_INIT_PATH => {
                if is_expected_hook_mount(mount) {
                    has_expected_hook_mount = true;
                } else {
                    return Err(WrapperError::InvalidSpec(format!(
                        "OCI mount destination {FEX_INIT_PATH} is reserved by Dory's amd64 runtime"
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
            "options": ["nosuid", "nodev", "mode=1777", "size=1m"]
        }));
        changed = true;
    }
    if !has_expected_hook_mount {
        mounts.push(json!({
            "destination": FEX_INIT_PATH,
            "type": "bind",
            "source": DORY_RUNC_PATH,
            "options": ["bind", "ro", "nosuid", "nodev"]
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

/// Interposes Dory's OCI admission wrapper when a privileged container carries its own runc.
/// Nested container managers otherwise bypass the outer engine wrapper, so their workloads reach
/// the host binfmt handler without the private FEXServer mount and fail at process startup.
fn inject_nested_runtime(
    spec: &mut Value,
    bundle: &Path,
    wrapper_source: &Path,
) -> Result<bool, WrapperError> {
    let has_sys_admin = spec
        .pointer("/process/capabilities/bounding")
        .and_then(Value::as_array)
        .is_some_and(|capabilities| {
            capabilities
                .iter()
                .any(|capability| capability.as_str() == Some("CAP_SYS_ADMIN"))
        });
    if !has_sys_admin {
        return Ok(false);
    }

    let root_path = spec
        .pointer("/root/path")
        .and_then(Value::as_str)
        .ok_or_else(|| WrapperError::InvalidSpec("OCI root.path must be a string".to_owned()))?;
    let root_path = Path::new(root_path);
    let root_path = if root_path.is_absolute() {
        root_path.to_path_buf()
    } else {
        bundle.join(root_path)
    };
    let canonical_root = fs::canonicalize(&root_path).map_err(|error| {
        io_error(
            format!("cannot resolve OCI root {}", root_path.display()),
            error,
        )
    })?;
    if !canonical_root.is_dir() {
        return Err(WrapperError::InvalidSpec(format!(
            "OCI root {} is not a directory",
            canonical_root.display()
        )));
    }

    let mut nested_runtime = None;
    for candidate in NESTED_RUNC_CANDIDATES {
        let path = canonical_root.join(candidate.trim_start_matches('/'));
        let Ok(canonical) = fs::canonicalize(&path) else {
            continue;
        };
        if !canonical.starts_with(&canonical_root) {
            return Err(WrapperError::InvalidSpec(format!(
                "nested runc {} resolves outside the OCI root",
                path.display()
            )));
        }
        let metadata = fs::metadata(&canonical).map_err(|error| {
            io_error(
                format!("cannot inspect nested runc {}", canonical.display()),
                error,
            )
        })?;
        if metadata.is_file() && metadata.permissions().mode() & 0o111 != 0 {
            nested_runtime = Some((candidate, canonical));
            break;
        }
    }
    let Some((nested_destination, nested_source)) = nested_runtime else {
        return Ok(false);
    };

    let wrapper_metadata = fs::metadata(wrapper_source).map_err(|error| {
        io_error(
            format!(
                "cannot inspect Dory nested-runtime wrapper {}",
                wrapper_source.display()
            ),
            error,
        )
    })?;
    if !wrapper_metadata.is_file() || wrapper_metadata.permissions().mode() & 0o111 == 0 {
        return Err(WrapperError::InvalidSpec(format!(
            "Dory nested-runtime wrapper {} is not an executable regular file",
            wrapper_source.display()
        )));
    }

    let mounts = spec
        .get_mut("mounts")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| {
            WrapperError::InvalidSpec("OCI config mounts must be an array".to_owned())
        })?;
    let expected_mounts = [
        (nested_source.as_path(), REAL_RUNC_PATH),
        (wrapper_source, DORY_RUNC_PATH),
        (wrapper_source, nested_destination),
    ];
    let mut expected_present = [false; 3];
    for mount in mounts.iter() {
        let destination = mount
            .get("destination")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                WrapperError::InvalidSpec("OCI mount is missing a string destination".to_owned())
            })?;
        let destination = normalized_destination(destination);
        if let Some((index, (source, _))) = expected_mounts
            .iter()
            .enumerate()
            .find(|(_, (_, expected_destination))| destination == *expected_destination)
        {
            let expected_options = json!(["bind", "ro", "nosuid", "nodev"]);
            let is_expected = mount.get("source").and_then(Value::as_str)
                == Some(source.to_string_lossy().as_ref())
                && mount.get("type").and_then(Value::as_str) == Some("bind")
                && mount.get("options") == Some(&expected_options);
            if !is_expected {
                return Err(WrapperError::InvalidSpec(format!(
                    "OCI mount destination {destination} is reserved by Dory's nested runtime"
                )));
            }
            expected_present[index] = true;
        }
    }

    if expected_present.iter().any(|present| *present) {
        if expected_present.iter().all(|present| *present) {
            return Ok(false);
        }
        return Err(WrapperError::InvalidSpec(
            "OCI config contains an incomplete Dory nested-runtime mount contract".to_owned(),
        ));
    }

    let bind_mount = |source: &Path, destination: &str| {
        json!({
            "destination": destination,
            "type": "bind",
            "source": source.to_string_lossy(),
            "options": ["bind", "ro", "nosuid", "nodev"]
        })
    };
    for (source, destination) in expected_mounts {
        mounts.push(bind_mount(source, destination));
    }
    Ok(true)
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
                        Value::String("mode=1777".to_owned()),
                        Value::String("size=1m".to_owned()),
                    ]
            })
}

fn is_expected_hook_mount(mount: &serde_json::Map<String, Value>) -> bool {
    mount.get("source").and_then(Value::as_str) == Some(DORY_RUNC_PATH)
        && mount.get("type").and_then(Value::as_str) == Some("bind")
        && mount
            .get("options")
            .and_then(Value::as_array)
            .is_some_and(|options| {
                options
                    == &[
                        Value::String("bind".to_owned()),
                        Value::String("ro".to_owned()),
                        Value::String("nosuid".to_owned()),
                        Value::String("nodev".to_owned()),
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

fn resolve_in_container_root(root: &Path, path: &Path) -> io::Result<PathBuf> {
    let mut pending = path
        .components()
        .filter_map(|component| match component {
            std::path::Component::Normal(value) => Some(value.to_os_string()),
            std::path::Component::ParentDir => Some(OsString::from("..")),
            _ => None,
        })
        .collect::<VecDeque<_>>();
    let mut resolved = root.to_path_buf();
    let mut symlinks = 0_u8;

    while let Some(component) = pending.pop_front() {
        if component == ".." {
            if resolved == root {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "container path escapes its root",
                ));
            }
            resolved.pop();
            continue;
        }

        let candidate = resolved.join(&component);
        let metadata = fs::symlink_metadata(&candidate)?;
        if !metadata.file_type().is_symlink() {
            resolved = candidate;
            continue;
        }

        symlinks = symlinks.saturating_add(1);
        if symlinks > 40 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "too many symlinks in container executable path",
            ));
        }
        let target = fs::read_link(&candidate)?;
        if target.is_absolute() {
            resolved = root.to_path_buf();
        }
        let target_components = target
            .components()
            .filter_map(|component| match component {
                std::path::Component::Normal(value) => Some(value.to_os_string()),
                std::path::Component::ParentDir => Some(OsString::from("..")),
                _ => None,
            })
            .collect::<Vec<_>>();
        for component in target_components.into_iter().rev() {
            pending.push_front(component);
        }
    }

    Ok(resolved)
}

fn executable_path(spec: &Value, bundle: &Path) -> Result<Option<PathBuf>, WrapperError> {
    let root_path = spec
        .pointer("/root/path")
        .and_then(Value::as_str)
        .ok_or_else(|| WrapperError::InvalidSpec("OCI root.path must be a string".to_owned()))?;
    let root_path = Path::new(root_path);
    let root_path = if root_path.is_absolute() {
        root_path.to_path_buf()
    } else {
        bundle.join(root_path)
    };
    let canonical_root = match fs::canonicalize(&root_path) {
        Ok(path) => path,
        Err(_) => return Ok(None),
    };
    let process = spec
        .get("process")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            WrapperError::InvalidSpec("OCI config process must be an object".to_owned())
        })?;
    let program = process
        .get("args")
        .and_then(Value::as_array)
        .and_then(|args| args.first())
        .and_then(Value::as_str)
        .ok_or_else(|| {
            WrapperError::InvalidSpec("OCI process args must not be empty".to_owned())
        })?;
    let cwd = process.get("cwd").and_then(Value::as_str).unwrap_or("/");
    let candidates = if program.contains('/') {
        let relative = if program.starts_with('/') {
            PathBuf::from(program.trim_start_matches('/'))
        } else {
            Path::new(cwd.trim_start_matches('/')).join(program)
        };
        vec![relative]
    } else {
        let path = process
            .get("env")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .find_map(|entry| entry.strip_prefix("PATH="))
            .unwrap_or(DEFAULT_PATH);
        path.split(':')
            .filter(|entry| !entry.is_empty())
            .map(|entry| Path::new(entry.trim_start_matches('/')).join(program))
            .collect()
    };
    for candidate in candidates {
        let Ok(canonical) = resolve_in_container_root(&canonical_root, &candidate) else {
            continue;
        };
        if canonical.starts_with(&canonical_root) && canonical.is_file() {
            return Ok(Some(canonical));
        }
    }
    Ok(None)
}

fn is_x86_64_executable(path: &Path, root: &Path, depth: u8) -> io::Result<bool> {
    if depth > 4 {
        return Ok(false);
    }
    let mut file = File::open(path)?;
    let mut header = [0_u8; 256];
    let length = file.read(&mut header)?;
    if length >= 20 && &header[..4] == b"\x7fELF" {
        return Ok(header[4] == 2 && header[5] == 1 && header[18] == 0x3e && header[19] == 0);
    }
    if length >= 3 && &header[..2] == b"#!" {
        let line = String::from_utf8_lossy(&header[2..length]);
        let interpreter = line.lines().next().unwrap_or("").split_whitespace().next();
        if let Some(interpreter) = interpreter.filter(|value| value.starts_with('/')) {
            let canonical =
                resolve_in_container_root(root, Path::new(interpreter.trim_start_matches('/')))?;
            if canonical.starts_with(root) {
                return is_x86_64_executable(&canonical, root, depth + 1);
            }
        }
    }
    Ok(false)
}

fn wrap_x86_64_entrypoint(spec: &mut Value, bundle: &Path) -> Result<bool, WrapperError> {
    let Some(executable) = executable_path(spec, bundle)? else {
        return Ok(false);
    };
    let root_path = spec
        .pointer("/root/path")
        .and_then(Value::as_str)
        .expect("validated root path");
    let root = if Path::new(root_path).is_absolute() {
        fs::canonicalize(root_path)
    } else {
        fs::canonicalize(bundle.join(root_path))
    }
    .map_err(|error| io_error("cannot resolve OCI root for amd64 detection", error))?;
    if !is_x86_64_executable(&executable, &root, 0)
        .map_err(|error| io_error(format!("cannot inspect {}", executable.display()), error))?
    {
        return Ok(false);
    }
    let args = spec
        .pointer_mut("/process/args")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| WrapperError::InvalidSpec("OCI process args must be an array".to_owned()))?;
    if args.first().and_then(Value::as_str) == Some(FEX_INIT_PATH) {
        return Ok(false);
    }
    let original = std::mem::take(args);
    args.push(Value::String(FEX_INIT_PATH.to_owned()));
    args.push(Value::String("fex-init".to_owned()));
    args.extend(original);
    Ok(true)
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
    let fex_changed = inject_fex(&mut spec)?;
    let init_changed = wrap_x86_64_entrypoint(&mut spec, bundle)?;
    let nested_changed = inject_nested_runtime(&mut spec, bundle, Path::new(DORY_RUNC_PATH))?;
    if !fex_changed && !init_changed && !nested_changed {
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

    fn privileged_spec(environment: &[&str]) -> Value {
        let mut value = spec(environment);
        value["process"]["capabilities"] = json!({
            "bounding": ["CAP_CHOWN", "CAP_SYS_ADMIN"]
        });
        value
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

        assert_eq!(value["mounts"].as_array().unwrap().len(), 3);
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
            json!(["nosuid", "nodev", "mode=1777", "size=1m"])
        );
        assert_eq!(value["mounts"][2]["source"], DORY_RUNC_PATH);
        assert_eq!(value["mounts"][2]["destination"], FEX_INIT_PATH);
        assert_eq!(
            value["mounts"][2]["options"],
            json!(["bind", "ro", "nosuid", "nodev"])
        );
    }

    #[test]
    fn wraps_only_x86_64_entrypoints_with_native_fex_init() {
        let directory = temporary_directory("entrypoint-architecture");
        let executable = directory.join("rootfs/bin/sh");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        let mut x86_header = vec![0_u8; 64];
        x86_header[..6].copy_from_slice(b"\x7fELF\x02\x01");
        x86_header[18] = 0x3e;
        fs::write(&executable, &x86_header).unwrap();

        let mut value = spec(&[]);
        assert!(wrap_x86_64_entrypoint(&mut value, &directory).unwrap());
        assert_eq!(
            value["process"]["args"],
            json!([FEX_INIT_PATH, "fex-init", "/bin/sh"])
        );
        assert!(!wrap_x86_64_entrypoint(&mut value, &directory).unwrap());

        value["process"]["args"] = json!(["/bin/sh"]);
        x86_header[18] = 0xb7;
        fs::write(&executable, &x86_header).unwrap();
        assert!(!wrap_x86_64_entrypoint(&mut value, &directory).unwrap());
        assert_eq!(value["process"]["args"], json!(["/bin/sh"]));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn resolves_absolute_entrypoint_symlinks_inside_the_container_root() {
        let directory = temporary_directory("absolute-entrypoint-symlink");
        let root = directory.join("rootfs");
        let executable = root.join("bin/busybox");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        let mut x86_header = vec![0_u8; 64];
        x86_header[..6].copy_from_slice(b"\x7fELF\x02\x01");
        x86_header[18] = 0x3e;
        fs::write(&executable, x86_header).unwrap();
        std::os::unix::fs::symlink("/bin/busybox", root.join("bin/sh")).unwrap();

        let mut value = spec(&[]);
        assert!(wrap_x86_64_entrypoint(&mut value, &directory).unwrap());
        assert_eq!(
            value["process"]["args"],
            json!([FEX_INIT_PATH, "fex-init", "/bin/sh"])
        );
        fs::remove_dir_all(directory).unwrap();
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
    fn privileged_nested_runc_is_interposed_without_image_specific_detection() {
        let directory = temporary_directory("nested-runc");
        let rootfs = directory.join("rootfs");
        let nested = rootfs.join("usr/local/sbin/runc");
        let wrapper = directory.join("dory-runc");
        fs::create_dir_all(nested.parent().unwrap()).unwrap();
        fs::write(&nested, b"nested-runc").unwrap();
        fs::write(&wrapper, b"dory-runc").unwrap();
        fs::set_permissions(&nested, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o755)).unwrap();

        let mut value = privileged_spec(&[]);
        assert!(inject_nested_runtime(&mut value, &directory, &wrapper).unwrap());
        assert!(!inject_nested_runtime(&mut value, &directory, &wrapper).unwrap());
        let mounts = value["mounts"].as_array().unwrap();
        assert_eq!(mounts.len(), 3);
        assert_eq!(
            mounts[0]["source"],
            fs::canonicalize(&nested)
                .unwrap()
                .to_string_lossy()
                .as_ref()
        );
        assert_eq!(mounts[0]["destination"], REAL_RUNC_PATH);
        assert_eq!(mounts[1]["source"], wrapper.to_string_lossy().as_ref());
        assert_eq!(mounts[1]["destination"], DORY_RUNC_PATH);
        assert_eq!(mounts[2]["destination"], "/usr/local/sbin/runc");
        assert_eq!(
            mounts[2]["options"],
            json!(["bind", "ro", "nosuid", "nodev"])
        );

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn unprivileged_container_never_receives_nested_runtime_interposition() {
        let directory = temporary_directory("unprivileged-nested-runc");
        let nested = directory.join("rootfs/usr/local/sbin/runc");
        let wrapper = directory.join("dory-runc");
        fs::create_dir_all(nested.parent().unwrap()).unwrap();
        fs::write(&nested, b"nested-runc").unwrap();
        fs::write(&wrapper, b"dory-runc").unwrap();
        fs::set_permissions(&nested, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&wrapper, fs::Permissions::from_mode(0o755)).unwrap();

        let mut value = spec(&[]);
        assert!(!inject_nested_runtime(&mut value, &directory, &wrapper).unwrap());
        assert!(value["mounts"].as_array().unwrap().is_empty());

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
