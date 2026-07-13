use dory_runc_wrapper::{prepare_for_args, record_runc_error};
use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};

// Docker's embedded BuildKit executor invokes the conventional runc path directly and does not
// honor dockerd's named/default-runtime selection. The initfs therefore keeps the vendor binary at
// runc.real and points both runc and dory-runc at this wrapper.
const REAL_RUNC: &str = "/usr/local/bin/runc.real";

fn main() -> ExitCode {
    let arguments: Vec<OsString> = std::env::args_os().skip(1).collect();
    let current_directory = match std::env::current_dir() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("dory-runc: cannot determine current directory: {error}");
            return ExitCode::from(125);
        }
    };
    if let Err(error) = prepare_for_args(&arguments, &current_directory) {
        let message = format!("dory-runc: refusing unsafe OCI config: {error}");
        let _ = record_runc_error(&arguments, &current_directory, &message);
        eprintln!("{message}");
        return ExitCode::from(125);
    }

    let error = Command::new(REAL_RUNC).args(&arguments).exec();
    eprintln!("dory-runc: cannot exec {REAL_RUNC}: {error}");
    ExitCode::from(125)
}
