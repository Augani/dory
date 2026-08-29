//! Capability-gated virtio-fs mounting for qualified Linux guests.
//!
//! This module deliberately owns the mount syscall and its proof. Host callers supply a validated
//! device tag, canonical absolute guest path, and access mode; the agent creates the target without
//! following symlinks, calls `mount(2)` directly, and accepts success only when
//! `/proc/self/mountinfo` reports the exact same authority. Replaying an identical request is safe,
//! while an occupied or mode-mismatched target fails closed.

use std::io;

use dory_pb::agent;
use thiserror::Error;

pub const CAPABILITY_ID: &str = "virtiofs-mount";
pub const CAPABILITY_VERSION: u32 = 1;

const MAX_TAG_BYTES: usize = 35;
const MAX_PATH_BYTES: usize = 4_095;
const MAX_COMPONENT_BYTES: usize = 255;

#[derive(Debug, Error)]
pub enum VirtiofsMountError {
    #[error("virtio-fs tag must be 1..={MAX_TAG_BYTES} ASCII bytes containing only letters, numbers, '.', '_', or '-'")]
    InvalidTag,
    #[error("virtio-fs mount_path must be a canonical absolute path below '/' with components no longer than {MAX_COMPONENT_BYTES} bytes")]
    InvalidMountPath,
    #[error("virtio-fs mount support is unavailable: {0}")]
    Unavailable(String),
    #[error("virtio-fs mount target is already occupied by a different mount authority: {0}")]
    Conflict(String),
    #[error("failed to prepare the virtio-fs mount target: {0}")]
    Target(String),
    #[error("virtio-fs mount(2) failed: {0}")]
    Mount(String),
    #[error("kernel mount proof failed: {0}")]
    Proof(String),
    #[error("virtio-fs mount worker failed: {0}")]
    Worker(String),
}

impl VirtiofsMountError {
    pub fn code(&self) -> i32 {
        match self {
            Self::InvalidTag | Self::InvalidMountPath => 422,
            Self::Conflict(_) => 409,
            Self::Unavailable(_) => 503,
            Self::Target(_) | Self::Mount(_) | Self::Proof(_) | Self::Worker(_) => 500,
        }
    }
}

/// Advertise the capability only when this process can exercise the Linux mount authority. Dory's
/// production guest agent runs as root; a non-root or non-Linux build must remain fail-explicit.
pub fn available() -> bool {
    platform::available()
}

pub async fn mount(
    request: agent::VirtiofsMountRequest,
) -> Result<agent::VirtiofsMountResponse, VirtiofsMountError> {
    validate_request(&request)?;
    if !available() {
        return Err(VirtiofsMountError::Unavailable(
            "the agent lacks Linux root/CAP_SYS_ADMIN mount authority or mountinfo access".into(),
        ));
    }
    tokio::task::spawn_blocking(move || {
        let mut runtime = platform::PlatformRuntime;
        mount_with_runtime(&request, &mut runtime)
    })
    .await
    .map_err(|error| VirtiofsMountError::Worker(error.to_string()))?
}

fn validate_request(request: &agent::VirtiofsMountRequest) -> Result<(), VirtiofsMountError> {
    let tag = request.tag.as_bytes();
    if tag.is_empty()
        || tag.len() > MAX_TAG_BYTES
        || !tag
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(VirtiofsMountError::InvalidTag);
    }

    let path = request.mount_path.as_bytes();
    if path.len() < 2
        || path.len() > MAX_PATH_BYTES
        || path.first() != Some(&b'/')
        || path.last() == Some(&b'/')
        || path.contains(&0)
    {
        return Err(VirtiofsMountError::InvalidMountPath);
    }
    if path[1..].split(|byte| *byte == b'/').any(|component| {
        component.is_empty()
            || component == b"."
            || component == b".."
            || component.len() > MAX_COMPONENT_BYTES
    }) {
        return Err(VirtiofsMountError::InvalidMountPath);
    }
    Ok(())
}

trait MountRuntime {
    type Target;

    fn mountinfo(&mut self) -> io::Result<Vec<u8>>;
    fn prepare_target(&mut self, path: &str) -> io::Result<Self::Target>;
    fn mount_virtiofs(
        &mut self,
        target: &Self::Target,
        tag: &str,
        read_only: bool,
    ) -> io::Result<()>;
    fn rollback_mount(&mut self, target: &Self::Target) -> io::Result<()>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct MountObservation {
    mount_id: u64,
    filesystem_type: Vec<u8>,
    source: Vec<u8>,
    read_only: bool,
}

fn mount_with_runtime<R: MountRuntime>(
    request: &agent::VirtiofsMountRequest,
    runtime: &mut R,
) -> Result<agent::VirtiofsMountResponse, VirtiofsMountError> {
    validate_request(request)?;

    let initial = runtime
        .mountinfo()
        .map_err(|error| VirtiofsMountError::Unavailable(error.to_string()))?;
    if let Some(observation) = observe_mount(&initial, request.mount_path.as_bytes())? {
        return receipt_for(request, observation, true);
    }

    let target = runtime
        .prepare_target(&request.mount_path)
        .map_err(|error| VirtiofsMountError::Target(error.to_string()))?;
    if let Err(error) = runtime.mount_virtiofs(&target, &request.tag, request.read_only) {
        // Another actor may have won the check-to-mount race. EBUSY is idempotent only when a
        // fresh kernel observation proves the exact requested authority.
        if error.raw_os_error() == Some(libc::EBUSY) {
            let raced = runtime
                .mountinfo()
                .map_err(|read_error| VirtiofsMountError::Proof(read_error.to_string()))?;
            if let Some(observation) = observe_mount(&raced, request.mount_path.as_bytes())? {
                return receipt_for(request, observation, true);
            }
        }
        return Err(VirtiofsMountError::Mount(error.to_string()));
    }

    let proof = runtime
        .mountinfo()
        .map_err(|error| VirtiofsMountError::Proof(error.to_string()))
        .and_then(|bytes| observe_mount(&bytes, request.mount_path.as_bytes()));
    match proof {
        Ok(Some(observation)) => match receipt_for(request, observation, false) {
            Ok(receipt) => Ok(receipt),
            Err(error) => Err(rollback_after_unproved_mount(runtime, &target, error)),
        },
        Ok(None) => Err(rollback_after_unproved_mount(
            runtime,
            &target,
            VirtiofsMountError::Proof("mount is absent from /proc/self/mountinfo".into()),
        )),
        Err(error) => Err(rollback_after_unproved_mount(runtime, &target, error)),
    }
}

fn rollback_after_unproved_mount<R: MountRuntime>(
    runtime: &mut R,
    target: &R::Target,
    error: VirtiofsMountError,
) -> VirtiofsMountError {
    match runtime.rollback_mount(target) {
        Ok(()) => error,
        Err(rollback) => VirtiofsMountError::Proof(format!(
            "{error}; rollback umount(2) also failed: {rollback}"
        )),
    }
}

fn receipt_for(
    request: &agent::VirtiofsMountRequest,
    observation: MountObservation,
    already_mounted: bool,
) -> Result<agent::VirtiofsMountResponse, VirtiofsMountError> {
    if observation.filesystem_type != b"virtiofs" {
        return Err(VirtiofsMountError::Conflict(
            "filesystem type is not virtiofs".into(),
        ));
    }
    if observation.source != request.tag.as_bytes() {
        return Err(VirtiofsMountError::Conflict(
            "virtio-fs device tag differs from the requested tag".into(),
        ));
    }
    if observation.read_only != request.read_only {
        return Err(VirtiofsMountError::Conflict(
            "kernel-observed read-only mode differs from the requested mode".into(),
        ));
    }
    Ok(agent::VirtiofsMountResponse {
        mounted: true,
        already_mounted,
        tag: request.tag.clone(),
        mount_path: request.mount_path.clone(),
        read_only: request.read_only,
        mount_id: observation.mount_id,
    })
}

fn observe_mount(
    mountinfo: &[u8],
    requested_path: &[u8],
) -> Result<Option<MountObservation>, VirtiofsMountError> {
    let mut found = None;
    for line in mountinfo
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
    {
        let separator = line
            .windows(3)
            .position(|window| window == b" - ")
            .ok_or_else(|| VirtiofsMountError::Proof("malformed mountinfo separator".into()))?;
        let left = ascii_fields(&line[..separator]);
        let right = ascii_fields(&line[separator + 3..]);
        if left.len() < 6 || right.len() < 3 {
            return Err(VirtiofsMountError::Proof(
                "malformed mountinfo field count".into(),
            ));
        }
        let mount_path = unescape_mountinfo_field(left[4])?;
        if mount_path != requested_path {
            continue;
        }
        if found.is_some() {
            return Err(VirtiofsMountError::Conflict(
                "multiple stacked mounts occupy the requested path".into(),
            ));
        }
        let mount_id = std::str::from_utf8(left[0])
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .ok_or_else(|| VirtiofsMountError::Proof("invalid mountinfo mount ID".into()))?;
        let read_only = parse_read_only(left[5])?;
        found = Some(MountObservation {
            mount_id,
            filesystem_type: right[0].to_vec(),
            source: unescape_mountinfo_field(right[1])?,
            read_only,
        });
    }
    Ok(found)
}

fn ascii_fields(bytes: &[u8]) -> Vec<&[u8]> {
    bytes
        .split(|byte| byte.is_ascii_whitespace())
        .filter(|field| !field.is_empty())
        .collect()
}

fn parse_read_only(options: &[u8]) -> Result<bool, VirtiofsMountError> {
    let mut read_only = None;
    for option in options.split(|byte| *byte == b',') {
        match option {
            b"ro" => set_mount_access_mode(&mut read_only, true)?,
            b"rw" => set_mount_access_mode(&mut read_only, false)?,
            _ => {}
        }
    }
    read_only
        .ok_or_else(|| VirtiofsMountError::Proof("mountinfo omits the mount access mode".into()))
}

fn set_mount_access_mode(
    selected: &mut Option<bool>,
    read_only: bool,
) -> Result<(), VirtiofsMountError> {
    if selected.replace(read_only).is_some() {
        return Err(VirtiofsMountError::Proof(
            "mountinfo contains conflicting access modes".into(),
        ));
    }
    Ok(())
}

fn unescape_mountinfo_field(field: &[u8]) -> Result<Vec<u8>, VirtiofsMountError> {
    let mut decoded = Vec::with_capacity(field.len());
    let mut index = 0;
    while index < field.len() {
        if field[index] != b'\\' {
            decoded.push(field[index]);
            index += 1;
            continue;
        }
        if index + 3 >= field.len()
            || !(b'0'..=b'7').contains(&field[index + 1])
            || !(b'0'..=b'7').contains(&field[index + 2])
            || !(b'0'..=b'7').contains(&field[index + 3])
        {
            return Err(VirtiofsMountError::Proof(
                "malformed mountinfo escape".into(),
            ));
        }
        let value = (field[index + 1] - b'0') * 64
            + (field[index + 2] - b'0') * 8
            + (field[index + 3] - b'0');
        decoded.push(value);
        index += 4;
    }
    Ok(decoded)
}

#[cfg(target_os = "linux")]
mod platform {
    use std::ffi::CString;
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::ptr;

    use super::MountRuntime;

    pub struct PlatformRuntime;

    pub fn available() -> bool {
        (unsafe { libc::geteuid() == 0 })
            && has_effective_cap_sys_admin()
            && std::fs::File::open("/proc/self/mountinfo").is_ok()
    }

    fn has_effective_cap_sys_admin() -> bool {
        const CAP_SYS_ADMIN: u32 = 21;
        std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|status| {
                status
                    .lines()
                    .find_map(|line| line.strip_prefix("CapEff:"))
                    .and_then(|value| u64::from_str_radix(value.trim(), 16).ok())
            })
            .is_some_and(|capabilities| capabilities & (1_u64 << CAP_SYS_ADMIN) != 0)
    }

    impl MountRuntime for PlatformRuntime {
        type Target = OwnedFd;

        fn mountinfo(&mut self) -> io::Result<Vec<u8>> {
            std::fs::read("/proc/self/mountinfo")
        }

        fn prepare_target(&mut self, path: &str) -> io::Result<Self::Target> {
            let mut current = open_directory_at(libc::AT_FDCWD, "/")?;
            for component in path.split('/').skip(1) {
                match open_directory_at(current.as_raw_fd(), component) {
                    Ok(next) => current = next,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {
                        let component = c_string(component)?;
                        let result = unsafe {
                            libc::mkdirat(current.as_raw_fd(), component.as_ptr(), 0o755)
                        };
                        if result != 0 {
                            let mkdir_error = io::Error::last_os_error();
                            if mkdir_error.kind() != io::ErrorKind::AlreadyExists {
                                return Err(mkdir_error);
                            }
                        }
                        current = open_directory_at_c(current.as_raw_fd(), &component)?;
                    }
                    Err(error) => return Err(error),
                }
            }
            Ok(current)
        }

        fn mount_virtiofs(
            &mut self,
            target: &Self::Target,
            tag: &str,
            read_only: bool,
        ) -> io::Result<()> {
            let source = c_string(tag)?;
            let target = c_string(&format!("/proc/self/fd/{}", target.as_raw_fd()))?;
            let filesystem = c_string("virtiofs")?;
            let flags = if read_only { libc::MS_RDONLY } else { 0 } as libc::c_ulong;
            let result = unsafe {
                libc::mount(
                    source.as_ptr(),
                    target.as_ptr(),
                    filesystem.as_ptr(),
                    flags,
                    ptr::null(),
                )
            };
            if result == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        }

        fn rollback_mount(&mut self, target: &Self::Target) -> io::Result<()> {
            let target = c_string(&format!("/proc/self/fd/{}", target.as_raw_fd()))?;
            let result = unsafe { libc::umount2(target.as_ptr(), 0) };
            if result == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        }
    }

    fn open_directory_at(parent: libc::c_int, name: &str) -> io::Result<OwnedFd> {
        open_directory_at_c(parent, &c_string(name)?)
    }

    fn open_directory_at_c(parent: libc::c_int, name: &CString) -> io::Result<OwnedFd> {
        let descriptor = unsafe {
            libc::openat(
                parent,
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if descriptor < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: openat returned a new owned descriptor and this is its only owner.
        Ok(unsafe { OwnedFd::from_raw_fd(descriptor) })
    }

    fn c_string(value: &str) -> io::Result<CString> {
        CString::new(value).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "value contains an interior NUL",
            )
        })
    }
}

#[cfg(not(target_os = "linux"))]
mod platform {
    use std::io;

    use super::MountRuntime;

    pub struct PlatformRuntime;

    pub fn available() -> bool {
        false
    }

    impl MountRuntime for PlatformRuntime {
        type Target = ();

        fn mountinfo(&mut self) -> io::Result<Vec<u8>> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "direct virtio-fs mounting is Linux-only",
            ))
        }

        fn prepare_target(&mut self, _path: &str) -> io::Result<Self::Target> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "direct virtio-fs mounting is Linux-only",
            ))
        }

        fn mount_virtiofs(
            &mut self,
            _target: &Self::Target,
            _tag: &str,
            _read_only: bool,
        ) -> io::Result<()> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "direct virtio-fs mounting is Linux-only",
            ))
        }

        fn rollback_mount(&mut self, _target: &Self::Target) -> io::Result<()> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "direct virtio-fs mounting is Linux-only",
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;

    use super::*;

    #[cfg(not(target_os = "linux"))]
    #[tokio::test]
    async fn rpc_fails_explicitly_when_mount_capability_is_not_advertised() {
        let error = mount(request(false))
            .await
            .expect_err("non-Linux agents must not accept the optional Linux mount RPC");
        assert!(matches!(error, VirtiofsMountError::Unavailable(_)));
        assert_eq!(error.code(), 503);
    }

    struct FakeRuntime {
        mountinfo: VecDeque<Vec<u8>>,
        mount_error: Option<io::Error>,
        prepared: usize,
        mounts: Vec<(String, bool)>,
        rollbacks: usize,
    }

    impl FakeRuntime {
        fn new(mountinfo: impl IntoIterator<Item = Vec<u8>>) -> Self {
            Self {
                mountinfo: mountinfo.into_iter().collect(),
                mount_error: None,
                prepared: 0,
                mounts: Vec::new(),
                rollbacks: 0,
            }
        }
    }

    impl MountRuntime for FakeRuntime {
        type Target = ();

        fn mountinfo(&mut self) -> io::Result<Vec<u8>> {
            self.mountinfo
                .pop_front()
                .ok_or_else(|| io::Error::new(io::ErrorKind::UnexpectedEof, "no fixture"))
        }

        fn prepare_target(&mut self, _path: &str) -> io::Result<Self::Target> {
            self.prepared += 1;
            Ok(())
        }

        fn mount_virtiofs(
            &mut self,
            _target: &Self::Target,
            tag: &str,
            read_only: bool,
        ) -> io::Result<()> {
            self.mounts.push((tag.to_string(), read_only));
            match self.mount_error.take() {
                Some(error) => Err(error),
                None => Ok(()),
            }
        }

        fn rollback_mount(&mut self, _target: &Self::Target) -> io::Result<()> {
            self.rollbacks += 1;
            Ok(())
        }
    }

    fn request(read_only: bool) -> agent::VirtiofsMountRequest {
        agent::VirtiofsMountRequest {
            tag: "workspace".into(),
            mount_path: "/mnt/dory/My Projects".into(),
            read_only,
        }
    }

    fn proof(id: u64, tag: &str, path: &str, read_only: bool) -> Vec<u8> {
        let path = path
            .replace('\\', "\\134")
            .replace(' ', "\\040")
            .replace('\t', "\\011")
            .replace('\n', "\\012");
        let mode = if read_only { "ro" } else { "rw" };
        format!("{id} 1 0:99 / {path} {mode},relatime - virtiofs {tag} {mode}\n").into_bytes()
    }

    #[test]
    fn validates_exact_tag_and_canonical_path_envelopes() {
        for tag in ["", "has space", "slash/tag", &"a".repeat(36)] {
            let mut invalid = request(false);
            invalid.tag = tag.into();
            assert!(matches!(
                validate_request(&invalid),
                Err(VirtiofsMountError::InvalidTag)
            ));
        }
        for path in [
            "/",
            "relative/path",
            "/trailing/",
            "/double//slash",
            "/dot/./path",
            "/parent/../path",
        ] {
            let mut invalid = request(false);
            invalid.mount_path = path.into();
            assert!(matches!(
                validate_request(&invalid),
                Err(VirtiofsMountError::InvalidMountPath)
            ));
        }
        assert!(validate_request(&request(false)).is_ok());
    }

    #[test]
    fn mountinfo_parser_decodes_kernel_escapes_and_access_mode() {
        let observation = observe_mount(
            &proof(91, "workspace", "/mnt/dory/My Projects", true),
            b"/mnt/dory/My Projects",
        )
        .unwrap()
        .unwrap();
        assert_eq!(observation.mount_id, 91);
        assert_eq!(observation.filesystem_type, b"virtiofs");
        assert_eq!(observation.source, b"workspace");
        assert!(observation.read_only);
    }

    #[test]
    fn identical_replay_is_idempotent_without_a_second_mount_syscall() {
        let request = request(false);
        let mut runtime = FakeRuntime::new([proof(
            42,
            &request.tag,
            &request.mount_path,
            request.read_only,
        )]);

        let response = mount_with_runtime(&request, &mut runtime).unwrap();

        assert!(response.mounted);
        assert!(response.already_mounted);
        assert_eq!(response.mount_id, 42);
        assert_eq!(runtime.prepared, 0);
        assert!(runtime.mounts.is_empty());
    }

    #[test]
    fn occupied_target_with_different_authority_fails_closed() {
        let request = request(false);
        let mut runtime = FakeRuntime::new([proof(
            17,
            "different-tag",
            &request.mount_path,
            request.read_only,
        )]);

        assert!(matches!(
            mount_with_runtime(&request, &mut runtime),
            Err(VirtiofsMountError::Conflict(_))
        ));
        assert_eq!(runtime.prepared, 0);
        assert!(runtime.mounts.is_empty());
    }

    #[test]
    fn occupied_target_with_different_access_mode_fails_closed() {
        let request = request(true);
        let mut runtime = FakeRuntime::new([proof(18, &request.tag, &request.mount_path, false)]);

        assert!(matches!(
            mount_with_runtime(&request, &mut runtime),
            Err(VirtiofsMountError::Conflict(_))
        ));
        assert_eq!(runtime.prepared, 0);
        assert!(runtime.mounts.is_empty());
    }

    #[test]
    fn new_mount_returns_only_after_exact_kernel_proof() {
        let request = request(true);
        let mut runtime = FakeRuntime::new([
            Vec::new(),
            proof(73, &request.tag, &request.mount_path, request.read_only),
        ]);

        let response = mount_with_runtime(&request, &mut runtime).unwrap();

        assert!(!response.already_mounted);
        assert_eq!(response.mount_id, 73);
        assert_eq!(runtime.prepared, 1);
        assert_eq!(runtime.mounts, [("workspace".into(), true)]);
        assert_eq!(runtime.rollbacks, 0);
    }

    #[test]
    fn missing_post_mount_proof_rolls_back_before_reporting_failure() {
        let request = request(false);
        let mut runtime = FakeRuntime::new([Vec::new(), Vec::new()]);

        assert!(matches!(
            mount_with_runtime(&request, &mut runtime),
            Err(VirtiofsMountError::Proof(_))
        ));
        assert_eq!(runtime.rollbacks, 1);
    }

    #[test]
    fn mismatched_post_mount_proof_rolls_back_before_reporting_failure() {
        let request = request(false);
        let mut runtime = FakeRuntime::new([
            Vec::new(),
            proof(74, "different-tag", &request.mount_path, request.read_only),
        ]);

        assert!(matches!(
            mount_with_runtime(&request, &mut runtime),
            Err(VirtiofsMountError::Conflict(_))
        ));
        assert_eq!(runtime.rollbacks, 1);
    }

    #[test]
    fn busy_race_is_idempotent_only_with_fresh_exact_proof() {
        let request = request(false);
        let mut runtime = FakeRuntime::new([
            Vec::new(),
            proof(84, &request.tag, &request.mount_path, request.read_only),
        ]);
        runtime.mount_error = Some(io::Error::from_raw_os_error(libc::EBUSY));

        let response = mount_with_runtime(&request, &mut runtime).unwrap();

        assert!(response.already_mounted);
        assert_eq!(response.mount_id, 84);
    }
}
