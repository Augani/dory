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
use crate::sync_apply::{self, SyncError};

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
        Some(Method::Exec(r)) => wrap_exec(exec::run(r).await),
        other => handle_method(other),
    };
    response.encode_to_vec()
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
