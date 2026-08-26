//! The async RPC handler the mux invokes per request. It routes the filesystem-touching sync methods
//! to [`crate::sync_apply`] (async `tokio::fs`) and everything else to the synchronous
//! [`crate::dispatch`]. Decoding failures and sync errors become well-formed error responses, never
//! panics — one bad request can't take the mux down.

use dory_pb::agent::{
    self, agent_request::Method, agent_response::Result as Res, AgentRequest, AgentResponse,
};
use prost::Message;

use crate::dispatch::{err, handle_method};
use crate::exec::{self, ExecError};
use crate::snapshot_quiesce;
use crate::sync_apply::{self, SyncError};
use crate::usb_vhci::{self, UsbVhciError};
use crate::virtiofs_mount::{self, VirtiofsMountError};

pub async fn handle(req_bytes: &[u8]) -> Vec<u8> {
    let req = match AgentRequest::decode(req_bytes) {
        Ok(req) => req,
        Err(_) => return err(400, "malformed AgentRequest").encode_to_vec(),
    };

    let response = match req.method {
        Some(Method::SyncManifest(r)) => wrap(sync_apply::manifest(r).await, Res::SyncManifest),
        Some(Method::SyncFileStatus(r)) => {
            wrap(sync_apply::file_status(r).await, Res::SyncFileStatus)
        }
        Some(Method::SyncPutChunk(r)) => wrap(sync_apply::put_chunk(r).await, Res::SyncPutChunk),
        Some(Method::SyncDelete(r)) => wrap(sync_apply::delete(r).await, Res::SyncDelete),
        Some(Method::SyncTree(r)) => wrap(sync_apply::tree(r).await, Res::SyncTree),
        Some(Method::SyncReadTree(r)) => wrap(sync_apply::read_tree(r).await, Res::SyncReadTree),
        Some(Method::SyncGetChunk(r)) => wrap(sync_apply::get_chunk(r).await, Res::SyncGetChunk),
        Some(Method::Exec(r)) => wrap_exec(exec::run(r).await),
        Some(Method::SnapshotQuiesce(r)) => AgentResponse {
            result: Some(Res::SnapshotQuiesce(snapshot_quiesce::run(r).await)),
        },
        Some(Method::UsbVhciAttach(r)) => wrap_usb(usb_vhci::attach(r).await, Res::UsbVhciAttach),
        Some(Method::UsbVhciDetach(r)) => wrap_usb(usb_vhci::detach(r).await, Res::UsbVhciDetach),
        Some(Method::VirtiofsMount(r)) => {
            wrap_virtiofs_mount(virtiofs_mount::mount(r).await, Res::VirtiofsMount)
        }
        other => handle_method(other),
    };
    response.encode_to_vec()
}

fn wrap_virtiofs_mount<T>(
    result: Result<T, VirtiofsMountError>,
    ok: impl FnOnce(T) -> Res,
) -> AgentResponse {
    match result {
        Ok(value) => agent::AgentResponse {
            result: Some(ok(value)),
        },
        Err(error) => err(error.code(), &error.to_string()),
    }
}

fn wrap_usb<T>(result: Result<T, UsbVhciError>, ok: impl FnOnce(T) -> Res) -> AgentResponse {
    match result {
        Ok(value) => agent::AgentResponse {
            result: Some(ok(value)),
        },
        Err(error) => err(error.code(), &error.to_string()),
    }
}

/// Turn a sync handler result into an `AgentResponse`: the ok variant, or a coded RpcError.
fn wrap<T>(result: Result<T, SyncError>, ok: impl FnOnce(T) -> Res) -> AgentResponse {
    match result {
        Ok(value) => agent::AgentResponse {
            result: Some(ok(value)),
        },
        Err(e) => err(e.code(), &e.to_string()),
    }
}

fn wrap_exec(result: Result<agent::ExecResponse, ExecError>) -> AgentResponse {
    match result {
        Ok(value) => agent::AgentResponse {
            result: Some(Res::Exec(value)),
        },
        Err(e) => err(e.code(), &e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn usb_vhci_requests_are_routed_and_rejected_before_platform_io() {
        let request = AgentRequest {
            method: Some(Method::UsbVhciAttach(agent::UsbVhciAttachRequest {
                bus_id: "../device".into(),
                port: 0,
                vsock_port: dory_proto::channels::PORT_USBIP,
                device_id: (3 << 16) | 2,
                speed: 3,
            })),
        };
        let response = AgentResponse::decode(handle(&request.encode_to_vec()).await.as_slice())
            .expect("well-formed response");
        match response.result {
            Some(Res::Error(error)) => assert_eq!(error.code, 422),
            other => panic!("expected validation error, got {other:?}"),
        }

        let request = AgentRequest {
            method: Some(Method::UsbVhciDetach(agent::UsbVhciDetachRequest {
                bus_id: "3-2".into(),
                port: 128,
            })),
        };
        let response = AgentResponse::decode(handle(&request.encode_to_vec()).await.as_slice())
            .expect("well-formed response");
        match response.result {
            Some(Res::Error(error)) => assert_eq!(error.code, 422),
            other => panic!("expected validation error, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn virtiofs_mount_requests_are_validated_before_platform_io() {
        let request = AgentRequest {
            method: Some(Method::VirtiofsMount(agent::VirtiofsMountRequest {
                tag: "../workspace".into(),
                mount_path: "/mnt/dory/workspace".into(),
                read_only: false,
            })),
        };
        let response = AgentResponse::decode(handle(&request.encode_to_vec()).await.as_slice())
            .expect("well-formed response");
        match response.result {
            Some(Res::Error(error)) => assert_eq!(error.code, 422),
            other => panic!("expected validation error, got {other:?}"),
        }

        let request = AgentRequest {
            method: Some(Method::VirtiofsMount(agent::VirtiofsMountRequest {
                tag: "workspace".into(),
                mount_path: "/mnt/../workspace".into(),
                read_only: true,
            })),
        };
        let response = AgentResponse::decode(handle(&request.encode_to_vec()).await.as_slice())
            .expect("well-formed response");
        match response.result {
            Some(Res::Error(error)) => assert_eq!(error.code, 422),
            other => panic!("expected validation error, got {other:?}"),
        }
    }
}
