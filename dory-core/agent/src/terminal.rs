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

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::io::unix::AsyncFd;

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
    let term_key = CString::new("TERM").unwrap();
    let term_value = CString::new("xterm-256color").unwrap();

    let mut master: libc::c_int = -1;
    let pid = unsafe {
        libc::forkpty(
            &mut master,
            ptr::null_mut(),
            ptr::null(),
            ptr::null(),
        )
    };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        unsafe {
            libc::setenv(term_key.as_ptr(), term_value.as_ptr(), 0);
            libc::execl(shell.as_ptr(), arg0.as_ptr(), ptr::null::<libc::c_char>());
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
            Ok(Ok(0)) => return Err(io::Error::new(io::ErrorKind::WriteZero, "pty write returned zero")),
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

    #[test]
    fn selects_existing_shell() {
        let process = spawn_shell().expect("spawn shell");
        unsafe {
            libc::kill(process.pid, libc::SIGKILL);
            let mut status = 0;
            let _ = libc::waitpid(process.pid, &mut status, 0);
        }
    }
}
