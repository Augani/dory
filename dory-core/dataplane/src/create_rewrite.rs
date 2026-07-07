//! Container-create body rewrites for shared-VM compatibility. Ports the behaviors covered by the
//! Swift `SharedVMCreateCompatibilityTests`:
//!
//! 1. A loopback `HostIp` in a port binding (`127.0.0.1`, `::1`, `localhost`) is emptied, so the
//!    port is published where the host-side forwarder can see it instead of being pinned to the
//!    guest's loopback.
//! 2. `host.docker.internal` / `host.dory.internal` are ensured as `host-gateway` `ExtraHosts`, so
//!    containers can reach the macOS host.
//! 3. A `--gpus` request (a GPU device request) is rejected with a 501-class error when GPU is not
//!    supported, rather than failing opaquely deep in the engine.

use serde_json::Value;

pub struct RewriteOpts {
    pub gpu_supported: bool,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum RewriteError {
    #[error("GPU requested but not supported by this engine")]
    GpuUnsupported,
}

const EXTRA_HOSTS: &[&str] = &["host.docker.internal", "host.dory.internal"];

/// Rewrite a `POST /containers/create` JSON body. A body that isn't a JSON object is returned
/// unchanged (passthrough) rather than rejected.
pub fn rewrite_create_body(body: &[u8], opts: &RewriteOpts) -> Result<Vec<u8>, RewriteError> {
    let mut root: Value = match serde_json::from_slice(body) {
        Ok(v) => v,
        Err(_) => return Ok(body.to_vec()),
    };
    let Some(obj) = root.as_object_mut() else {
        return Ok(body.to_vec());
    };

    let host_config = obj
        .entry("HostConfig")
        .or_insert_with(|| Value::Object(Default::default()));
    if let Some(hc) = host_config.as_object_mut() {
        normalize_port_bindings(hc);
        ensure_extra_hosts(hc);
        if has_gpu_request(hc) && !opts.gpu_supported {
            return Err(RewriteError::GpuUnsupported);
        }
    }

    Ok(serde_json::to_vec(&root).unwrap_or_else(|_| body.to_vec()))
}

fn is_loopback(host_ip: &str) -> bool {
    matches!(host_ip, "127.0.0.1" | "::1" | "localhost") || host_ip.starts_with("127.")
}

fn normalize_port_bindings(hc: &mut serde_json::Map<String, Value>) {
    let Some(bindings) = hc.get_mut("PortBindings").and_then(Value::as_object_mut) else {
        return;
    };
    for entry in bindings.values_mut() {
        let Some(list) = entry.as_array_mut() else {
            continue;
        };
        for binding in list {
            let Some(map) = binding.as_object_mut() else {
                continue;
            };
            if let Some(Value::String(ip)) = map.get("HostIp") {
                if is_loopback(ip) {
                    map.insert("HostIp".into(), Value::String(String::new()));
                }
            }
        }
    }
}

fn ensure_extra_hosts(hc: &mut serde_json::Map<String, Value>) {
    let list = hc
        .entry("ExtraHosts")
        .or_insert_with(|| Value::Array(Vec::new()));
    // The docker CLI (Go) marshals an empty list as an explicit `"ExtraHosts": null`, which
    // `or_insert_with` keeps as-is — treat any non-array as empty or the injection silently skips.
    if !list.is_array() {
        *list = Value::Array(Vec::new());
    }
    let Some(arr) = list.as_array_mut() else {
        return;
    };
    for host in EXTRA_HOSTS {
        let prefix = format!("{host}:");
        let present = arr
            .iter()
            .any(|v| v.as_str().is_some_and(|s| s.starts_with(&prefix)));
        if !present {
            arr.push(Value::String(format!("{host}:host-gateway")));
        }
    }
}

fn has_gpu_request(hc: &serde_json::Map<String, Value>) -> bool {
    let Some(requests) = hc.get("DeviceRequests").and_then(Value::as_array) else {
        return false;
    };
    requests.iter().any(|req| {
        // Driver "nvidia", or a capability group containing "gpu".
        if req.get("Driver").and_then(Value::as_str) == Some("nvidia") {
            return true;
        }
        req.get("Capabilities")
            .and_then(Value::as_array)
            .is_some_and(|groups| {
                groups.iter().any(|g| {
                    g.as_array()
                        .is_some_and(|caps| caps.iter().any(|c| c.as_str() == Some("gpu")))
                })
            })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rewrite(v: Value, gpu_supported: bool) -> Result<Value, RewriteError> {
        let out = rewrite_create_body(v.to_string().as_bytes(), &RewriteOpts { gpu_supported })?;
        Ok(serde_json::from_slice(&out).unwrap())
    }

    #[test]
    fn loopback_host_ip_is_emptied() {
        let out = rewrite(
            json!({"HostConfig": {"PortBindings": {"80/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]}}}),
            false,
        )
        .unwrap();
        assert_eq!(out["HostConfig"]["PortBindings"]["80/tcp"][0]["HostIp"], "");
        assert_eq!(
            out["HostConfig"]["PortBindings"]["80/tcp"][0]["HostPort"],
            "8080"
        );
    }

    #[test]
    fn non_loopback_host_ip_preserved() {
        let out = rewrite(
            json!({"HostConfig": {"PortBindings": {"80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "8080"}]}}}),
            false,
        )
        .unwrap();
        assert_eq!(
            out["HostConfig"]["PortBindings"]["80/tcp"][0]["HostIp"],
            "0.0.0.0"
        );
    }

    /// The docker CLI (Go) always sends `"ExtraHosts": null` for an empty list — the injection
    /// must treat that as empty, not silently skip (found on hardware 2026-07-07: HostIp was
    /// rewritten but ExtraHosts stayed null through a real `docker create`).
    #[test]
    fn explicit_null_extra_hosts_still_gets_injected() {
        let out = rewrite(json!({"HostConfig": {"ExtraHosts": null}}), false).unwrap();
        let hosts = out["HostConfig"]["ExtraHosts"].as_array().unwrap();
        assert!(hosts.contains(&json!("host.docker.internal:host-gateway")));
        assert!(hosts.contains(&json!("host.dory.internal:host-gateway")));
    }

    #[test]
    fn extra_hosts_added_once() {
        let out = rewrite(json!({"HostConfig": {}}), false).unwrap();
        let hosts = out["HostConfig"]["ExtraHosts"].as_array().unwrap();
        assert!(hosts.contains(&json!("host.docker.internal:host-gateway")));
        assert!(hosts.contains(&json!("host.dory.internal:host-gateway")));

        // Idempotent + does not clobber a user's explicit mapping.
        let again = rewrite(
            json!({"HostConfig": {"ExtraHosts": ["host.docker.internal:1.2.3.4"]}}),
            false,
        )
        .unwrap();
        let hosts = again["HostConfig"]["ExtraHosts"].as_array().unwrap();
        assert!(hosts.contains(&json!("host.docker.internal:1.2.3.4")));
        assert!(hosts.contains(&json!("host.dory.internal:host-gateway")));
        assert_eq!(
            hosts
                .iter()
                .filter(|h| h.as_str().unwrap().starts_with("host.docker.internal:"))
                .count(),
            1
        );
    }

    #[test]
    fn gpu_request_rejected_when_unsupported() {
        let body = json!({"HostConfig": {"DeviceRequests": [{"Capabilities": [["gpu"]]}]}});
        assert_eq!(
            rewrite(body.clone(), false),
            Err(RewriteError::GpuUnsupported)
        );
        assert!(rewrite(body, true).is_ok()); // supported -> passes through
    }

    #[test]
    fn nvidia_driver_counts_as_gpu() {
        let body = json!({"HostConfig": {"DeviceRequests": [{"Driver": "nvidia", "Count": -1}]}});
        assert_eq!(rewrite(body, false), Err(RewriteError::GpuUnsupported));
    }

    #[test]
    fn non_object_body_passes_through() {
        let out = rewrite_create_body(
            b"not json",
            &RewriteOpts {
                gpu_supported: false,
            },
        )
        .unwrap();
        assert_eq!(out, b"not json");
    }

    #[test]
    fn plain_create_gets_extra_hosts_but_no_ports() {
        let out = rewrite(json!({"Image": "alpine"}), false).unwrap();
        assert_eq!(out["Image"], "alpine");
        assert!(out["HostConfig"]["ExtraHosts"].as_array().unwrap().len() >= 2);
    }
}
