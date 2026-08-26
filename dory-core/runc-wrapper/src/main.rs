use dory_runc_wrapper::{
    prepare_for_args, record_runc_error, FEX_SERVER_PATH, FEX_SERVER_SOCKET_PATH, REAL_RUNC_PATH,
};
use std::ffi::OsString;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::process::CommandExt;
use std::os::unix::process::ExitStatusExt;
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::thread;
use std::time::{Duration, Instant};

static PENDING_SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn remember_signal(signal: libc::c_int) {
    PENDING_SIGNAL.store(signal, Ordering::Relaxed);
}

// Docker's embedded BuildKit executor invokes the conventional runc path directly and does not
// honor dockerd's named/default-runtime selection. The initfs therefore keeps the vendor binary at
// runc.real and points both runc and dory-runc at this wrapper.
fn main() -> ExitCode {
    let arguments: Vec<OsString> = std::env::args_os().skip(1).collect();
    if arguments.first().and_then(|argument| argument.to_str()) == Some("fex-init") {
        return run_fex_init(&arguments[1..]);
    }
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

    let error = Command::new(REAL_RUNC_PATH).args(&arguments).exec();
    eprintln!("dory-runc: cannot exec {REAL_RUNC_PATH}: {error}");
    ExitCode::from(125)
}

fn spawn_fex_server() -> Result<std::process::Child, String> {
    let mut server = match Command::new(FEX_SERVER_PATH)
        .args(["--foreground", "--persistent=30"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(server) => server,
        Err(error) => return Err(format!("cannot start {FEX_SERVER_PATH}: {error}")),
    };

    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        if std::fs::symlink_metadata(FEX_SERVER_SOCKET_PATH)
            .is_ok_and(|metadata| metadata.file_type().is_socket())
        {
            return Ok(server);
        }
        match server.try_wait() {
            Ok(Some(status)) => {
                return Err(format!(
                    "{FEX_SERVER_PATH} exited before readiness: {status}"
                ));
            }
            Err(error) => {
                return Err(format!("cannot observe {FEX_SERVER_PATH}: {error}"));
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                let _ = server.kill();
                return Err(format!(
                    "{FEX_SERVER_PATH} did not publish its socket before timeout"
                ));
            }
        }
    }
}

fn run_fex_init(arguments: &[OsString]) -> ExitCode {
    let Some(program) = arguments.first() else {
        eprintln!("dory-runc: fex-init requires a guest program");
        return ExitCode::from(125);
    };
    let mut server = match spawn_fex_server() {
        Ok(server) => server,
        Err(error) => {
            eprintln!("dory-runc: {error}");
            return ExitCode::from(125);
        }
    };

    for signal in [
        libc::SIGHUP,
        libc::SIGINT,
        libc::SIGQUIT,
        libc::SIGTERM,
        libc::SIGUSR1,
        libc::SIGUSR2,
        libc::SIGWINCH,
    ] {
        unsafe {
            libc::signal(signal, remember_signal as *const () as libc::sighandler_t);
        }
    }

    let mut command = Command::new(program);
    command.args(&arguments[1..]);
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut guest = match command.spawn() {
        Ok(guest) => guest,
        Err(error) => {
            let _ = server.kill();
            let _ = server.wait();
            eprintln!(
                "dory-runc: cannot start guest program {:?}: {error}",
                program
            );
            return ExitCode::from(127);
        }
    };
    let guest_pid = guest.id() as libc::pid_t;

    let status = loop {
        if let Some(signal) = match PENDING_SIGNAL.swap(0, Ordering::Relaxed) {
            0 => None,
            signal => Some(signal),
        } {
            unsafe {
                libc::kill(-guest_pid, signal);
            }
        }
        match guest.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(error) => {
                unsafe {
                    libc::kill(-guest_pid, libc::SIGKILL);
                }
                let _ = guest.wait();
                let _ = server.kill();
                let _ = server.wait();
                eprintln!("dory-runc: cannot observe guest program: {error}");
                return ExitCode::from(125);
            }
        }
        match server.try_wait() {
            Ok(Some(status)) => {
                unsafe {
                    libc::kill(-guest_pid, libc::SIGKILL);
                }
                let _ = guest.wait();
                eprintln!("dory-runc: {FEX_SERVER_PATH} exited while guest was running: {status}");
                return ExitCode::from(125);
            }
            Err(error) => {
                unsafe {
                    libc::kill(-guest_pid, libc::SIGKILL);
                }
                let _ = guest.wait();
                eprintln!("dory-runc: cannot observe {FEX_SERVER_PATH}: {error}");
                return ExitCode::from(125);
            }
            Ok(None) => thread::sleep(Duration::from_millis(10)),
        }
    };

    let _ = server.kill();
    let _ = server.wait();
    if let Some(code) = status.code() {
        ExitCode::from(u8::try_from(code.clamp(0, 255)).unwrap_or(125))
    } else {
        ExitCode::from(
            status
                .signal()
                .map(|signal| (128 + signal).clamp(0, 255) as u8)
                .unwrap_or(125),
        )
    }
}
