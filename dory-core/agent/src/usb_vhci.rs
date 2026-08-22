//! Guest-side USB/IP import and Linux vhci attachment.
//!
//! The host owns device selection and exposes the claimed device on the fixed USB/IP vsock port.
//! The guest agent still fails closed: it validates the request, performs the standard USB/IP
//! import handshake, verifies that the returned descriptor is the requested device, and only then
//! hands the connected socket fd to `vhci_hcd`.

use dory_pb::agent;
use std::time::Duration;
use thiserror::Error;

const USBIP_BUS_ID_BYTES: usize = 32;
const MAX_VHCI_PORT: u32 = 127;
const VHCI_OPERATION_TIMEOUT: Duration = Duration::from_secs(10);

#[cfg(any(target_os = "linux", test))]
const USBIP_VERSION: u16 = 0x0111;
#[cfg(any(target_os = "linux", test))]
const USBIP_REQ_IMPORT: u16 = 0x8003;
#[cfg(any(target_os = "linux", test))]
const USBIP_REP_IMPORT: u16 = 0x0003;
#[cfg(any(target_os = "linux", test))]
const USBIP_OPERATION_BYTES: usize = 8;
#[cfg(any(target_os = "linux", test))]
const USBIP_DEVICE_BYTES: usize = 312;
#[cfg(any(target_os = "linux", test))]
const USBIP_IMPORT_REQUEST_BYTES: usize = USBIP_OPERATION_BYTES + USBIP_BUS_ID_BYTES;
#[cfg(any(target_os = "linux", test))]
const USBIP_IMPORT_REPLY_BYTES: usize = USBIP_OPERATION_BYTES + USBIP_DEVICE_BYTES;

#[derive(Debug, Error)]
pub enum UsbVhciError {
    #[error("usb vhci is unavailable in this guest")]
    Unavailable,
    #[error("invalid USB bus id")]
    InvalidBusId,
    #[error("invalid vhci port {0}")]
    InvalidPort(u32),
    #[error("USB/IP must use the fixed vsock port {expected}, got {actual}")]
    InvalidVsockPort { expected: u32, actual: u32 },
    #[error("invalid USB device id")]
    InvalidDeviceId,
    #[error("invalid USB speed {0}")]
    InvalidSpeed(u32),
    #[error("USB/IP I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("USB/IP import reply is malformed")]
    MalformedImportReply,
    #[error("USB/IP host rejected device import with status {0}")]
    ImportRejected(u32),
    #[error("USB/IP host returned a different device")]
    ImportAuthorityMismatch,
    #[error("USB vhci worker failed: {0}")]
    Worker(String),
    #[error("USB vhci operation timed out")]
    Timeout,
}

impl UsbVhciError {
    pub fn code(&self) -> i32 {
        match self {
            Self::Unavailable => 503,
            Self::InvalidBusId
            | Self::InvalidPort(_)
            | Self::InvalidVsockPort { .. }
            | Self::InvalidDeviceId
            | Self::InvalidSpeed(_) => 422,
            Self::ImportRejected(_) => 409,
            Self::Timeout => 504,
            Self::Io(_)
            | Self::MalformedImportReply
            | Self::ImportAuthorityMismatch
            | Self::Worker(_) => 502,
        }
    }
}

pub fn available() -> bool {
    platform::available()
}

pub async fn attach(
    request: agent::UsbVhciAttachRequest,
) -> Result<agent::UsbVhciAttachResponse, UsbVhciError> {
    validate_attach(&request)?;
    tokio::time::timeout(VHCI_OPERATION_TIMEOUT, platform::attach(&request))
        .await
        .map_err(|_| UsbVhciError::Timeout)??;
    Ok(agent::UsbVhciAttachResponse {
        attached: true,
        bus_id: request.bus_id,
        port: request.port,
        device_id: request.device_id,
    })
}

pub async fn detach(
    request: agent::UsbVhciDetachRequest,
) -> Result<agent::UsbVhciDetachResponse, UsbVhciError> {
    validate_bus_id(&request.bus_id)?;
    validate_port(request.port)?;
    tokio::time::timeout(VHCI_OPERATION_TIMEOUT, platform::detach(request.port))
        .await
        .map_err(|_| UsbVhciError::Timeout)??;
    Ok(agent::UsbVhciDetachResponse {
        detached: true,
        bus_id: request.bus_id,
        port: request.port,
    })
}

fn validate_attach(request: &agent::UsbVhciAttachRequest) -> Result<(), UsbVhciError> {
    validate_bus_id(&request.bus_id)?;
    validate_port(request.port)?;
    if request.vsock_port != dory_proto::channels::PORT_USBIP {
        return Err(UsbVhciError::InvalidVsockPort {
            expected: dory_proto::channels::PORT_USBIP,
            actual: request.vsock_port,
        });
    }
    if request.device_id == 0 || request.device_id & 0xffff == 0 {
        return Err(UsbVhciError::InvalidDeviceId);
    }
    // Linux USB_SPEED_* values accepted by vhci_hcd: low, full, high, wireless, super,
    // super-plus. Unknown speed cannot be attached truthfully.
    if !(1..=6).contains(&request.speed) {
        return Err(UsbVhciError::InvalidSpeed(request.speed));
    }
    Ok(())
}

fn validate_bus_id(bus_id: &str) -> Result<(), UsbVhciError> {
    let bytes = bus_id.as_bytes();
    if bytes.is_empty()
        || bytes.len() >= USBIP_BUS_ID_BYTES
        || !bytes
            .iter()
            .all(|byte| byte.is_ascii_digit() || *byte == b'-' || *byte == b'.')
        || !bytes[0].is_ascii_digit()
        || !bytes[bytes.len() - 1].is_ascii_digit()
    {
        return Err(UsbVhciError::InvalidBusId);
    }
    Ok(())
}

fn validate_port(port: u32) -> Result<(), UsbVhciError> {
    if port > MAX_VHCI_PORT {
        return Err(UsbVhciError::InvalidPort(port));
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
fn import_request(bus_id: &str) -> [u8; USBIP_IMPORT_REQUEST_BYTES] {
    let mut bytes = [0_u8; USBIP_IMPORT_REQUEST_BYTES];
    bytes[0..2].copy_from_slice(&USBIP_VERSION.to_be_bytes());
    bytes[2..4].copy_from_slice(&USBIP_REQ_IMPORT.to_be_bytes());
    bytes[8..8 + bus_id.len()].copy_from_slice(bus_id.as_bytes());
    bytes
}

#[cfg(any(target_os = "linux", test))]
fn validate_import_reply(
    bytes: &[u8],
    request: &agent::UsbVhciAttachRequest,
) -> Result<(), UsbVhciError> {
    if bytes.len() != USBIP_IMPORT_REPLY_BYTES {
        return Err(UsbVhciError::MalformedImportReply);
    }
    validate_import_header(&bytes[..USBIP_OPERATION_BYTES])?;
    let status = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    if status != 0 {
        return Err(UsbVhciError::ImportRejected(status));
    }
    let descriptor = &bytes[USBIP_OPERATION_BYTES..];
    let bus_id = c_string(&descriptor[256..288])?;
    let bus_number = u32::from_be_bytes(descriptor[288..292].try_into().unwrap());
    let device_number = u32::from_be_bytes(descriptor[292..296].try_into().unwrap());
    let speed = u32::from_be_bytes(descriptor[296..300].try_into().unwrap());
    if bus_number > u16::MAX.into() || device_number == 0 || device_number > u16::MAX.into() {
        return Err(UsbVhciError::ImportAuthorityMismatch);
    }
    let device_id = (bus_number << 16) | device_number;
    if bus_id != request.bus_id || device_id != request.device_id || speed != request.speed {
        return Err(UsbVhciError::ImportAuthorityMismatch);
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
fn validate_import_header(bytes: &[u8]) -> Result<(), UsbVhciError> {
    if bytes.len() != USBIP_OPERATION_BYTES
        || u16::from_be_bytes([bytes[0], bytes[1]]) != USBIP_VERSION
        || u16::from_be_bytes([bytes[2], bytes[3]]) != USBIP_REP_IMPORT
    {
        return Err(UsbVhciError::MalformedImportReply);
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
fn c_string(bytes: &[u8]) -> Result<&str, UsbVhciError> {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    std::str::from_utf8(&bytes[..end]).map_err(|_| UsbVhciError::MalformedImportReply)
}

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use std::io::Write;
    use std::os::fd::AsRawFd;
    use std::path::{Path, PathBuf};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_vsock::{VsockAddr, VsockStream, VMADDR_CID_HOST};

    const VHCI_PLATFORM_ROOT: &str = "/sys/devices/platform";

    pub fn available() -> bool {
        control_files()
            .and_then(|(attach, detach)| {
                std::fs::OpenOptions::new().write(true).open(attach)?;
                std::fs::OpenOptions::new().write(true).open(detach)?;
                Ok(())
            })
            .is_ok()
    }

    pub async fn attach(request: &agent::UsbVhciAttachRequest) -> Result<(), UsbVhciError> {
        let mut stream = VsockStream::connect(VsockAddr::new(
            VMADDR_CID_HOST,
            dory_proto::channels::PORT_USBIP,
        ))
        .await?;
        AsyncWriteExt::write_all(&mut stream, &import_request(&request.bus_id)).await?;

        let mut header = [0_u8; USBIP_OPERATION_BYTES];
        stream.read_exact(&mut header).await?;
        validate_import_header(&header)?;
        let status = u32::from_be_bytes(header[4..8].try_into().unwrap());
        if status != 0 {
            return Err(UsbVhciError::ImportRejected(status));
        }
        let mut reply = [0_u8; USBIP_IMPORT_REPLY_BYTES];
        reply[..USBIP_OPERATION_BYTES].copy_from_slice(&header);
        stream
            .read_exact(&mut reply[USBIP_OPERATION_BYTES..])
            .await?;
        validate_import_reply(&reply, request)?;

        let socket_fd = stream.as_raw_fd();
        let command = format!(
            "{} {} {} {}",
            request.port, socket_fd, request.device_id, request.speed
        );
        tokio::task::spawn_blocking(move || write_control("attach", &command))
            .await
            .map_err(|error| UsbVhciError::Worker(error.to_string()))??;
        // vhci_hcd takes its own reference to the socket when the sysfs write succeeds.
        drop(stream);
        Ok(())
    }

    pub async fn detach(port: u32) -> Result<(), UsbVhciError> {
        tokio::task::spawn_blocking(move || write_control("detach", &port.to_string()))
            .await
            .map_err(|error| UsbVhciError::Worker(error.to_string()))??;
        Ok(())
    }

    fn write_control(name: &str, value: &str) -> Result<(), UsbVhciError> {
        let (attach, detach) = control_files()?;
        let path = match name {
            "attach" => attach,
            "detach" => detach,
            _ => return Err(UsbVhciError::Unavailable),
        };
        let mut file = std::fs::OpenOptions::new().write(true).open(path)?;
        file.write_all(value.as_bytes())?;
        Ok(())
    }

    fn control_files() -> std::io::Result<(PathBuf, PathBuf)> {
        let root = Path::new(VHCI_PLATFORM_ROOT);
        let mut controllers = std::fs::read_dir(root)?
            .filter_map(Result::ok)
            .filter(|entry| {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                name == "vhci_hcd" || name.starts_with("vhci_hcd.")
            })
            .map(|entry| entry.path())
            .collect::<Vec<_>>();
        controllers.sort();
        for controller in controllers {
            let attach = controller.join("attach");
            let detach = controller.join("detach");
            if attach.exists() && detach.exists() {
                return Ok((attach, detach));
            }
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "vhci_hcd sysfs controls are unavailable",
        ))
    }
}

#[cfg(not(target_os = "linux"))]
mod platform {
    use super::*;

    pub fn available() -> bool {
        false
    }

    pub async fn attach(_request: &agent::UsbVhciAttachRequest) -> Result<(), UsbVhciError> {
        Err(UsbVhciError::Unavailable)
    }

    pub async fn detach(_port: u32) -> Result<(), UsbVhciError> {
        Err(UsbVhciError::Unavailable)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> agent::UsbVhciAttachRequest {
        agent::UsbVhciAttachRequest {
            bus_id: "3-2.1".into(),
            port: 4,
            vsock_port: dory_proto::channels::PORT_USBIP,
            device_id: (3 << 16) | 2,
            speed: 3,
        }
    }

    fn success_reply(request: &agent::UsbVhciAttachRequest) -> Vec<u8> {
        let mut bytes = vec![0_u8; USBIP_IMPORT_REPLY_BYTES];
        bytes[0..2].copy_from_slice(&USBIP_VERSION.to_be_bytes());
        bytes[2..4].copy_from_slice(&USBIP_REP_IMPORT.to_be_bytes());
        let descriptor = &mut bytes[USBIP_OPERATION_BYTES..];
        descriptor[256..256 + request.bus_id.len()].copy_from_slice(request.bus_id.as_bytes());
        descriptor[288..292].copy_from_slice(&(request.device_id >> 16).to_be_bytes());
        descriptor[292..296].copy_from_slice(&(request.device_id & 0xffff).to_be_bytes());
        descriptor[296..300].copy_from_slice(&request.speed.to_be_bytes());
        bytes
    }

    #[test]
    fn import_request_matches_usbip_wire_contract() {
        let bytes = import_request("3-2.1");
        assert_eq!(bytes.len(), 40);
        assert_eq!(&bytes[0..2], &USBIP_VERSION.to_be_bytes());
        assert_eq!(&bytes[2..4], &USBIP_REQ_IMPORT.to_be_bytes());
        assert_eq!(&bytes[8..13], b"3-2.1");
        assert!(bytes[13..].iter().all(|byte| *byte == 0));
    }

    #[test]
    fn validation_rejects_untrusted_attach_coordinates() {
        let valid = request();
        assert!(validate_attach(&valid).is_ok());

        for bus_id in ["", "-1", "1-", "1/a", "é-1"] {
            let mut candidate = valid.clone();
            candidate.bus_id = bus_id.into();
            assert!(matches!(
                validate_attach(&candidate),
                Err(UsbVhciError::InvalidBusId)
            ));
        }

        let mut candidate = valid.clone();
        candidate.port = MAX_VHCI_PORT + 1;
        assert!(matches!(
            validate_attach(&candidate),
            Err(UsbVhciError::InvalidPort(_))
        ));

        let mut candidate = valid.clone();
        candidate.vsock_port += 1;
        assert!(matches!(
            validate_attach(&candidate),
            Err(UsbVhciError::InvalidVsockPort { .. })
        ));

        let mut candidate = valid.clone();
        candidate.speed = 0;
        assert!(matches!(
            validate_attach(&candidate),
            Err(UsbVhciError::InvalidSpeed(0))
        ));
    }

    #[test]
    fn import_reply_is_bound_to_exact_host_device() {
        let request = request();
        let reply = success_reply(&request);
        assert!(validate_import_reply(&reply, &request).is_ok());

        for mutate in ["bus", "device", "speed"] {
            let mut changed = reply.clone();
            match mutate {
                "bus" => changed[USBIP_OPERATION_BYTES + 256] = b'9',
                "device" => changed[USBIP_OPERATION_BYTES + 295] ^= 1,
                "speed" => changed[USBIP_OPERATION_BYTES + 299] ^= 1,
                _ => unreachable!(),
            }
            assert!(matches!(
                validate_import_reply(&changed, &request),
                Err(UsbVhciError::ImportAuthorityMismatch)
            ));
        }
    }

    #[test]
    fn import_reply_rejects_protocol_and_host_failure() {
        let request = request();
        let mut reply = success_reply(&request);
        reply[2..4].copy_from_slice(&0x9999_u16.to_be_bytes());
        assert!(matches!(
            validate_import_reply(&reply, &request),
            Err(UsbVhciError::MalformedImportReply)
        ));

        let mut reply = success_reply(&request);
        reply[4..8].copy_from_slice(&7_u32.to_be_bytes());
        assert!(matches!(
            validate_import_reply(&reply, &request),
            Err(UsbVhciError::ImportRejected(7))
        ));
    }
}
