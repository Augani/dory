//! Interactive guest shell served as a raw byte stream.
//!
//! This intentionally does not use the agent RPC mux: terminals are long-lived, noisy streams and
//! must not block control calls such as clock sync, telemetry, or bounded provisioning exec.

#![cfg(target_os = "linux")]

use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::Path;
use std::ptr;
use std::time::Duration;

use tokio::io::unix::AsyncFd;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

struct ShellProcess {
    pid: libc::pid_t,
    master: OwnedFd,
}

pub async fn serve_shell_stream<S>(stream: S) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let shell = spawn_shell()?;
    let read_fd = dup_fd(shell.master.as_raw_fd())?;
    set_nonblocking(read_fd.as_raw_fd())?;
    set_nonblocking(shell.master.as_raw_fd())?;

    let pty_read = AsyncFd::new(read_fd)?;
    let pty_write = AsyncFd::new(shell.master)?;
    let pid = shell.pid;
    let (mut stream_read, mut stream_write) = tokio::io::split(stream);

    let from_guest = copy_fd_to_writer(&pty_read, &mut stream_write);
    let to_guest = copy_reader_to_fd(&mut stream_read, &pty_write);

    tokio::select! {
        result = from_guest => {
            terminate_child(pid);
            result
        }
        result = to_guest => {
            terminate_child(pid);
            result
        }
    }
}

fn spawn_shell() -> io::Result<ShellProcess> {
    let shell_path = if Path::new("/bin/bash").exists() {
        "/bin/bash"
    } else {
        "/bin/sh"
    };
    let shell = CString::new(shell_path).expect("static shell path has no nul");
    let shell_name = Path::new(shell_path)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("sh");
    let arg0 = CString::new(format!("-{shell_name}")).expect("shell name has no nul");
    let argv: [*const libc::c_char; 2] = [arg0.as_ptr(), ptr::null()];

    // Build the child environment BEFORE forking: between fork and exec in a multithreaded process
    // only async-signal-safe calls are legal, and `setenv` (which may allocate) is not one of them.
    let env_strings: Vec<CString> = std::env::vars()
        .filter(|(key, _)| key != "TERM")
        .filter_map(|(key, value)| CString::new(format!("{key}={value}")).ok())
        .chain(std::iter::once(
            CString::new("TERM=xterm-256color").expect("static env has no nul"),
        ))
        .collect();
    let mut envp: Vec<*const libc::c_char> = env_strings.iter().map(|s| s.as_ptr()).collect();
    envp.push(ptr::null());

    let mut master: libc::c_int = -1;
    let pid = unsafe { libc::forkpty(&mut master, ptr::null_mut(), ptr::null(), ptr::null()) };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        unsafe {
            libc::execve(shell.as_ptr(), argv.as_ptr(), envp.as_ptr());
            libc::_exit(127);
        }
    }

    Ok(ShellProcess {
        pid,
        master: unsafe { OwnedFd::from_raw_fd(master) },
    })
}

async fn copy_fd_to_writer<W>(fd: &AsyncFd<OwnedFd>, writer: &mut W) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let n = read_fd(fd, &mut buffer).await?;
        if n == 0 {
            return Ok(());
        }
        writer.write_all(&buffer[..n]).await?;
        writer.flush().await?;
    }
}

async fn copy_reader_to_fd<R>(reader: &mut R, fd: &AsyncFd<OwnedFd>) -> io::Result<()>
where
    R: AsyncRead + Unpin,
{
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let n = reader.read(&mut buffer).await?;
        if n == 0 {
            return Ok(());
        }
        write_all_fd(fd, &buffer[..n]).await?;
    }
}

async fn read_fd(fd: &AsyncFd<OwnedFd>, buffer: &mut [u8]) -> io::Result<usize> {
    loop {
        let mut guard = fd.readable().await?;
        match guard.try_io(|inner| read_raw(inner.get_ref().as_raw_fd(), buffer)) {
            Ok(result) => return result,
            Err(_) => continue,
        }
    }
}

async fn write_all_fd(fd: &AsyncFd<OwnedFd>, mut bytes: &[u8]) -> io::Result<()> {
    while !bytes.is_empty() {
        let mut guard = fd.writable().await?;
        match guard.try_io(|inner| write_raw(inner.get_ref().as_raw_fd(), bytes)) {
            Ok(Ok(0)) => {
                return Err(io::Error::new(
                    io::ErrorKind::WriteZero,
                    "pty write returned zero",
                ))
            }
            Ok(Ok(n)) => bytes = &bytes[n..],
            Ok(Err(error)) => return Err(error),
            Err(_) => continue,
        }
    }
    Ok(())
}

fn read_raw(fd: RawFd, buffer: &mut [u8]) -> io::Result<usize> {
    loop {
        let n = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if n >= 0 {
            return Ok(n as usize);
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(libc::EAGAIN) => return Err(io::Error::from(io::ErrorKind::WouldBlock)),
            _ => return Err(error),
        }
    }
}

fn write_raw(fd: RawFd, bytes: &[u8]) -> io::Result<usize> {
    loop {
        let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
        if n >= 0 {
            return Ok(n as usize);
        }
        let error = io::Error::last_os_error();
        match error.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(libc::EAGAIN) => return Err(io::Error::from(io::ErrorKind::WouldBlock)),
            _ => return Err(error),
        }
    }
}

fn dup_fd(fd: RawFd) -> io::Result<OwnedFd> {
    let duped = unsafe { libc::dup(fd) };
    if duped < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { OwnedFd::from_raw_fd(duped) })
    }
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn terminate_child(pid: libc::pid_t) {
    tokio::spawn(async move {
        let _ = tokio::task::spawn_blocking(move || {
            unsafe {
                libc::kill(pid, libc::SIGHUP);
            }
            for _ in 0..10 {
                let mut status = 0;
                let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
                if waited == pid || waited < 0 {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            unsafe {
                libc::kill(pid, libc::SIGKILL);
                let mut status = 0;
                let _ = libc::waitpid(pid, &mut status, 0);
            }
        })
        .await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::UnixStream;

    const STREAM_TIMEOUT: Duration = Duration::from_secs(20);

    #[test]
    fn selects_existing_shell() {
        let process = spawn_shell().expect("spawn shell");
        unsafe {
            libc::kill(process.pid, libc::SIGKILL);
            let mut status = 0;
            let _ = libc::waitpid(process.pid, &mut status, 0);
        }
    }

    #[test]
    fn the_child_shell_receives_the_injected_term() {
        let shell = spawn_shell().expect("spawn shell");
        set_nonblocking(shell.master.as_raw_fd()).expect("nonblocking master");
        write_blocking(
            shell.master.as_raw_fd(),
            b"printf 'term=%s\\n' \"$TERM\"\nexit\n",
        );

        let transcript = read_until(shell.master.as_raw_fd(), "term=xterm-256color");
        terminate_child_blocking(shell.pid);
        assert!(transcript.contains("term=xterm-256color"), "{transcript}");
    }

    #[tokio::test]
    async fn the_stream_carries_shell_output_and_ends_when_the_shell_exits() {
        let (mut host, guest) = UnixStream::pair().expect("socket pair");
        let served = tokio::spawn(serve_shell_stream(guest));

        host.write_all(b"printf 'dory-%s\\n' ready\nexit\n")
            .await
            .expect("write command");
        host.flush().await.expect("flush command");

        let mut transcript = Vec::new();
        let mut buffer = [0_u8; 4096];
        let read = tokio::time::timeout(STREAM_TIMEOUT, async {
            loop {
                let count = host.read(&mut buffer).await?;
                if count == 0 {
                    return Ok::<(), io::Error>(());
                }
                transcript.extend_from_slice(&buffer[..count]);
                if String::from_utf8_lossy(&transcript).contains("dory-ready") {
                    return Ok(());
                }
            }
        })
        .await;
        assert!(read.is_ok(), "timed out reading the shell transcript");
        assert!(
            String::from_utf8_lossy(&transcript).contains("dory-ready"),
            "{}",
            String::from_utf8_lossy(&transcript)
        );

        // The shell exited, so the PTY read side reports EOF and both copy loops unwind.
        let outcome = tokio::time::timeout(STREAM_TIMEOUT, served).await;
        assert!(outcome.expect("shell stream ended").is_ok());
    }

    #[tokio::test]
    async fn closing_the_client_stream_tears_the_session_down() {
        let (host, guest) = UnixStream::pair().expect("socket pair");
        let served = tokio::spawn(serve_shell_stream(guest));
        drop(host);

        let outcome = tokio::time::timeout(STREAM_TIMEOUT, served).await;
        assert!(outcome.expect("shell stream ended").is_ok());
    }

    #[tokio::test]
    async fn pty_reads_and_writes_go_through_the_readiness_guards() {
        let shell = spawn_shell().expect("spawn shell");
        set_nonblocking(shell.master.as_raw_fd()).expect("nonblocking master");
        let pid = shell.pid;
        let pty = AsyncFd::new(shell.master).expect("register pty");

        write_all_fd(&pty, b"").await.expect("empty write");
        write_all_fd(&pty, b"printf 'guarded'\n")
            .await
            .expect("write command");
        let mut buffer = [0_u8; 4096];
        let count = tokio::time::timeout(STREAM_TIMEOUT, read_fd(&pty, &mut buffer))
            .await
            .expect("read did not time out")
            .expect("read");
        assert!(count > 0);
        terminate_child_blocking(pid);
    }

    #[test]
    fn raw_descriptor_helpers_surface_their_errors() {
        assert_eq!(dup_fd(-1).unwrap_err().raw_os_error(), Some(libc::EBADF));
        assert_eq!(
            set_nonblocking(-1).unwrap_err().raw_os_error(),
            Some(libc::EBADF)
        );
        assert_eq!(
            read_raw(-1, &mut [0_u8; 1]).unwrap_err().raw_os_error(),
            Some(libc::EBADF)
        );
        assert_eq!(
            write_raw(-1, b"x").unwrap_err().raw_os_error(),
            Some(libc::EBADF)
        );
    }

    fn write_blocking(fd: RawFd, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            match write_raw(fd, bytes) {
                Ok(count) => bytes = &bytes[count..],
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                Err(error) => panic!("pty write failed: {error}"),
            }
        }
    }

    fn read_until(fd: RawFd, marker: &str) -> String {
        let deadline = std::time::Instant::now() + STREAM_TIMEOUT;
        let mut output = Vec::new();
        let mut buffer = [0_u8; 4096];
        while std::time::Instant::now() < deadline {
            match read_raw(fd, &mut buffer) {
                Ok(0) => break,
                Ok(count) => output.extend_from_slice(&buffer[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                Err(_) => break,
            }
            if String::from_utf8_lossy(&output).contains(marker) {
                break;
            }
        }
        String::from_utf8_lossy(&output).into_owned()
    }

    fn terminate_child_blocking(pid: libc::pid_t) {
        unsafe {
            libc::kill(pid, libc::SIGKILL);
            let mut status = 0;
            let _ = libc::waitpid(pid, &mut status, 0);
        }
    }
}
