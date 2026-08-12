use dory_transfer_helper::{
    repair_volume, scan_volume, ManifestLimits, TransferHelperError, VolumeManifest,
};
use serde::Serialize;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

#[derive(Serialize)]
struct ScanReceipt {
    schema_version: u32,
    manifest_sha256: String,
    entry_count: usize,
    socket_count: usize,
    contains_device_nodes: bool,
}

#[derive(Serialize)]
struct RepairReceipt {
    schema_version: u32,
    source_manifest_sha256: String,
    target_manifest_sha256: String,
    verified_entry_count: usize,
    excluded_socket_count: usize,
}

fn main() {
    if let Err(error) = run(std::env::args().skip(1).collect()) {
        eprintln!("dory-transfer-helper: {error}");
        std::process::exit(1);
    }
}

fn run(arguments: Vec<String>) -> Result<(), TransferHelperError> {
    match arguments.as_slice() {
        [command, root_flag, root, output_flag, output]
            if command == "scan" && root_flag == "--root" && output_flag == "--output" =>
        {
            scan(Path::new(root), Path::new(output))
        }
        [command, root_flag, root, manifest_flag, manifest]
            if command == "repair"
                && root_flag == "--root"
                && manifest_flag == "--manifest" =>
        {
            repair(Path::new(root), Path::new(manifest))
        }
        _ => Err(TransferHelperError::InvalidManifest(
            "usage: dory-transfer-helper scan --root <path> --output <path> | repair --root <path> --manifest <path>".into(),
        )),
    }
}

fn scan(root: &Path, output: &Path) -> Result<(), TransferHelperError> {
    let limits = ManifestLimits::default();
    let manifest = scan_volume(root, limits)?;
    let bytes = manifest.canonical_json(limits)?;
    let digest = manifest.canonical_sha256(limits)?;
    write_atomic(output, &bytes)?;

    let receipt = ScanReceipt {
        schema_version: 1,
        manifest_sha256: digest,
        entry_count: manifest.entries.len(),
        socket_count: manifest.socket_paths().len(),
        contains_device_nodes: manifest.contains_device_nodes(),
    };
    println!("{}", serde_json::to_string(&receipt)?);
    Ok(())
}

fn repair(root: &Path, manifest_path: &Path) -> Result<(), TransferHelperError> {
    let limits = ManifestLimits::default();
    let source = read_manifest(manifest_path, limits)?;
    let source_digest = source.canonical_sha256(limits)?;
    let excluded_socket_count = source.socket_paths().len();
    let target = repair_volume(root, &source, limits)?;
    let receipt = RepairReceipt {
        schema_version: 1,
        source_manifest_sha256: source_digest,
        target_manifest_sha256: target.canonical_sha256(limits)?,
        verified_entry_count: target.entries.len(),
        excluded_socket_count,
    };
    println!("{}", serde_json::to_string(&receipt)?);
    Ok(())
}

fn read_manifest(
    path: &Path,
    limits: ManifestLimits,
) -> Result<VolumeManifest, TransferHelperError> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|source| filesystem_error(path, source))?;
    let metadata = file
        .metadata()
        .map_err(|source| filesystem_error(path, source))?;
    if !metadata.is_file() || metadata.nlink() != 1 {
        return Err(TransferHelperError::InvalidManifest(
            "manifest input must be a singly linked regular file".into(),
        ));
    }
    if metadata.len() > limits.maximum_manifest_bytes as u64 {
        return Err(TransferHelperError::Limit(format!(
            "manifest input is {} bytes; maximum is {}",
            metadata.len(),
            limits.maximum_manifest_bytes
        )));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)
        .map_err(|source| filesystem_error(path, source))?;
    if bytes.len() > limits.maximum_manifest_bytes {
        return Err(TransferHelperError::Limit(
            "manifest input grew beyond its byte limit".into(),
        ));
    }
    let manifest: VolumeManifest = serde_json::from_slice(&bytes)?;
    if manifest.canonical_json(limits)? != bytes {
        return Err(TransferHelperError::InvalidManifest(
            "manifest input is not canonical JSON".into(),
        ));
    }
    Ok(manifest)
}

fn write_atomic(path: &Path, contents: &[u8]) -> Result<(), TransferHelperError> {
    let parent = path.parent().ok_or_else(|| {
        TransferHelperError::InvalidManifest("output path has no parent directory".into())
    })?;
    let name = path.file_name().ok_or_else(|| {
        TransferHelperError::InvalidManifest("output path has no file name".into())
    })?;
    let temporary = parent.join(format!(".{}.partial", name.to_string_lossy()));
    let _ = fs::remove_file(&temporary);
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary)
        .map_err(|source| filesystem_error(&temporary, source))?;
    file.write_all(contents)
        .map_err(|source| filesystem_error(&temporary, source))?;
    file.sync_all()
        .map_err(|source| filesystem_error(&temporary, source))?;
    fs::rename(&temporary, path).map_err(|source| filesystem_error(path, source))?;
    let directory = fs::File::open(parent).map_err(|source| filesystem_error(parent, source))?;
    directory
        .sync_all()
        .map_err(|source| filesystem_error(parent, source))?;
    Ok(())
}

fn filesystem_error(path: &Path, source: std::io::Error) -> TransferHelperError {
    TransferHelperError::Filesystem {
        path: path.display().to_string(),
        source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    struct TempDirectory {
        path: PathBuf,
    }

    impl TempDirectory {
        fn new() -> Self {
            let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir()
                .join(format!("dory-helper-cli-{}-{unique}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).expect("create temporary directory");
            Self { path }
        }

        fn join(&self, relative: &str) -> PathBuf {
            self.path.join(relative)
        }
    }

    impl Drop for TempDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_string()).collect()
    }

    fn volume(directory: &TempDirectory, name: &str) -> PathBuf {
        let root = directory.join(name);
        fs::create_dir_all(root.join("nested")).unwrap();
        fs::write(root.join("nested/file"), b"payload").unwrap();
        std::os::unix::fs::symlink("nested/file", root.join("link")).unwrap();
        root
    }

    #[test]
    fn scan_then_repair_round_trips_through_the_manifest_file() {
        let directory = TempDirectory::new();
        let source = volume(&directory, "source");
        let manifest_path = directory.join("manifest.json");

        run(arguments(&[
            "scan",
            "--root",
            source.to_str().unwrap(),
            "--output",
            manifest_path.to_str().unwrap(),
        ]))
        .expect("scan");

        let limits = ManifestLimits::default();
        let manifest = read_manifest(&manifest_path, limits).expect("read manifest");
        assert_eq!(manifest.entries.len(), 3);
        assert!(!manifest.contains_device_nodes());

        let target = volume(&directory, "target");
        run(arguments(&[
            "repair",
            "--root",
            target.to_str().unwrap(),
            "--manifest",
            manifest_path.to_str().unwrap(),
        ]))
        .expect("repair");

        assert_eq!(
            scan_volume(&target, limits)
                .unwrap()
                .canonical_sha256(limits)
                .unwrap(),
            manifest.canonical_sha256(limits).unwrap()
        );
    }

    #[test]
    fn unrecognized_argument_shapes_report_the_usage_contract() {
        let rejected: Vec<Vec<String>> = vec![
            arguments(&[]),
            arguments(&["scan"]),
            arguments(&["scan", "--root", "/tmp", "--out", "/tmp/manifest"]),
            arguments(&["repair", "--root", "/tmp", "--output", "/tmp/manifest"]),
            arguments(&["verify", "--root", "/tmp", "--manifest", "/tmp/manifest"]),
            arguments(&[
                "scan",
                "--root",
                "/tmp",
                "--output",
                "/tmp/manifest",
                "extra",
            ]),
        ];
        for value in rejected {
            match run(value.clone()) {
                Err(TransferHelperError::InvalidManifest(message)) => {
                    assert!(message.starts_with("usage:"), "{message}")
                }
                other => panic!("{value:?} was not rejected: {other:?}"),
            }
        }
    }

    #[test]
    fn manifest_input_must_be_a_canonical_singly_linked_regular_file() {
        let directory = TempDirectory::new();
        let limits = ManifestLimits::default();

        let missing = directory.join("absent.json");
        assert!(matches!(
            read_manifest(&missing, limits),
            Err(TransferHelperError::Filesystem { .. })
        ));

        let not_json = directory.join("not-json.json");
        fs::write(&not_json, b"{").unwrap();
        assert!(matches!(
            read_manifest(&not_json, limits),
            Err(TransferHelperError::Encoding(_))
        ));

        let source = volume(&directory, "source");
        let canonical = directory.join("manifest.json");
        let manifest = scan_volume(&source, limits).unwrap();
        write_atomic(&canonical, &manifest.canonical_json(limits).unwrap()).unwrap();
        assert_eq!(read_manifest(&canonical, limits).unwrap(), manifest);

        let reformatted = directory.join("reformatted.json");
        fs::write(&reformatted, serde_json::to_vec_pretty(&manifest).unwrap()).unwrap();
        assert!(matches!(
            read_manifest(&reformatted, limits),
            Err(TransferHelperError::InvalidManifest(_))
        ));

        let oversized = ManifestLimits {
            maximum_manifest_bytes: 1,
            ..limits
        };
        assert!(matches!(
            read_manifest(&canonical, oversized),
            Err(TransferHelperError::Limit(_))
        ));

        let linked = directory.join("linked.json");
        fs::hard_link(&canonical, &linked).unwrap();
        assert!(matches!(
            read_manifest(&linked, limits),
            Err(TransferHelperError::InvalidManifest(_))
        ));
    }

    #[test]
    fn atomic_writes_replace_stale_partials_and_reject_unusable_paths() {
        let directory = TempDirectory::new();
        let output = directory.join("receipt.json");
        fs::write(directory.join(".receipt.json.partial"), b"stale").unwrap();

        write_atomic(&output, b"first").unwrap();
        assert_eq!(fs::read(&output).unwrap(), b"first");
        write_atomic(&output, b"second").unwrap();
        assert_eq!(fs::read(&output).unwrap(), b"second");
        assert!(!directory.join(".receipt.json.partial").exists());

        assert!(matches!(
            write_atomic(Path::new("/"), b"payload"),
            Err(TransferHelperError::InvalidManifest(_))
        ));
        assert!(matches!(
            write_atomic(&directory.join("absent/receipt.json"), b"payload"),
            Err(TransferHelperError::Filesystem { .. })
        ));
    }
}
