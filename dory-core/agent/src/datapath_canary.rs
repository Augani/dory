//! Engine-only HTTP witness for the host's gvproxy datapath guard.
//!
//! The canary belongs to the long-lived guest agent rather than a boot-shell background job. That
//! gives it the same lifecycle as the engine guest, bounds every admitted connection, and makes a
//! listener failure fatal to the agent so the supervisor can recover the whole engine coherently.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::time::timeout;

pub const PORT_ENVIRONMENT_KEY: &str = "DORY_DATAPATH_CANARY_PORT";

const MAX_CONCURRENT_CONNECTIONS: usize = 16;
const MAX_REQUEST_BYTES: usize = 1_024;
const IO_TIMEOUT: Duration = Duration::from_secs(2);
const OK_RESPONSE: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
const NOT_FOUND_RESPONSE: &[u8] =
    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const BAD_REQUEST_RESPONSE: &[u8] =
    b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

pub fn configured_port() -> io::Result<Option<u16>> {
    parse_port(std::env::var(PORT_ENVIRONMENT_KEY).ok().as_deref())
}

fn parse_port(value: Option<&str>) -> io::Result<Option<u16>> {
    let Some(value) = value else {
        return Ok(None);
    };
    let port = value.parse::<u16>().map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{PORT_ENVIRONMENT_KEY} must be a non-zero TCP port"),
        )
    })?;
    if port == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{PORT_ENVIRONMENT_KEY} must be a non-zero TCP port"),
        ));
    }
    Ok(Some(port))
}

pub async fn run_from_environment() -> io::Result<()> {
    let Some(port) = configured_port()? else {
        return Ok(());
    };
    let listener = TcpListener::bind(("0.0.0.0", port)).await?;
    serve(listener).await
}

pub async fn serve(listener: TcpListener) -> io::Result<()> {
    let permits = Arc::new(Semaphore::new(MAX_CONCURRENT_CONNECTIONS));
    loop {
        let (stream, _) = listener.accept().await?;
        let Ok(permit) = Arc::clone(&permits).try_acquire_owned() else {
            continue;
        };
        tokio::spawn(async move {
            let _permit = permit;
            let _ = handle(stream).await;
        });
    }
}

async fn handle(mut stream: TcpStream) -> io::Result<()> {
    let response = match timeout(IO_TIMEOUT, read_request(&mut stream)).await {
        Ok(Ok(request)) if is_ping_request(&request) => OK_RESPONSE,
        Ok(Ok(_)) => NOT_FOUND_RESPONSE,
        Ok(Err(error)) if error.kind() == io::ErrorKind::InvalidData => BAD_REQUEST_RESPONSE,
        Ok(Err(error)) => return Err(error),
        Err(_) => {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out reading datapath canary request",
            ));
        }
    };
    timeout(IO_TIMEOUT, stream.write_all(response))
        .await
        .map_err(|_| {
            io::Error::new(
                io::ErrorKind::TimedOut,
                "timed out writing datapath canary response",
            )
        })??;
    let _ = stream.shutdown().await;
    Ok(())
}

async fn read_request(stream: &mut TcpStream) -> io::Result<Vec<u8>> {
    let mut request = Vec::with_capacity(256);
    let mut chunk = [0_u8; 256];
    loop {
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        if request.len() + read > MAX_REQUEST_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "datapath canary request exceeds maximum size",
            ));
        }
        request.extend_from_slice(&chunk[..read]);
        if request.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    Ok(request)
}

fn is_ping_request(request: &[u8]) -> bool {
    request.starts_with(b"GET /_ping HTTP/1.1\r\n")
        || request.starts_with(b"GET /_ping HTTP/1.0\r\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn port_configuration_is_optional_and_strict() {
        assert_eq!(parse_port(None).unwrap(), None);
        assert_eq!(parse_port(Some("2380")).unwrap(), Some(2_380));
        assert!(parse_port(Some("0")).is_err());
        assert!(parse_port(Some("not-a-port")).is_err());
        assert!(parse_port(Some("65536")).is_err());
    }

    #[tokio::test]
    async fn serves_only_the_inert_ping_endpoint() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(serve(listener));

        let response = request(address, b"GET /_ping HTTP/1.1\r\nHost: dory\r\n\r\n").await;
        assert_eq!(response, OK_RESPONSE);

        let response = request(address, b"GET /containers/json HTTP/1.1\r\n\r\n").await;
        assert_eq!(response, NOT_FOUND_RESPONSE);

        server.abort();
    }

    async fn request(address: std::net::SocketAddr, request: &[u8]) -> Vec<u8> {
        let mut stream = TcpStream::connect(address).await.unwrap();
        stream.write_all(request).await.unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).await.unwrap();
        response
    }
}
