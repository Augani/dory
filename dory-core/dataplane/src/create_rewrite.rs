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
//! 4. A bind of Dory's macOS proxy socket onto `/var/run/docker.sock` is rebound to the daemon's
//!    guest-local socket. Tools such as Supabase derive the bind source directly from `DOCKER_HOST`;
//!    that host path cannot exist as a Unix socket inside the Linux VM.

use serde_json::Value;

pub struct RewriteOpts {
    pub gpu_supported: bool,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum RewriteError {
    #[error("GPU requested but not supported by this engine")]
    GpuUnsupported,
    #[error("Dory GPU requests require the single Vulkan render device: {0}")]
    GpuRequestUnsupported(&'static str),
}

const EXTRA_HOSTS: &[&str] = &["host.docker.internal", "host.dory.internal"];
/// dory-hv reads this internal label back from `/containers/json` after dockerd has replaced the
/// normalized empty HostIp with a wildcard. Without it, enabling LAN publication could widen a
/// user's explicit loopback-only request. User input under this key is always replaced/removed.
pub const LOOPBACK_PORT_INTENT_LABEL: &str = "dev.dory.internal.loopback-port-intent";

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
    // The Go docker SDK marshals a nil HostConfig as an explicit `"HostConfig": null` (e.g.
    // ContainerCreate(ctx, config, nil, ...)). or_insert_with only fires on a VACANT entry, so a
    // present-but-null value would otherwise fall through as_object_mut and skip EVERY rewrite —
    // the same null-as-empty bug this crate fixed one level down for ExtraHosts. Coerce to empty.
    if !host_config.is_object() {
        *host_config = Value::Object(Default::default());
    }
    let mut loopback_port_intents = serde_json::Map::new();
    if let Some(hc) = host_config.as_object_mut() {
        loopback_port_intents = normalize_port_bindings(hc);
        normalize_dory_socket_mounts(hc);
        ensure_extra_hosts(hc);
        normalize_gpu_requests(hc, opts.gpu_supported)?;
    }
    preserve_loopback_port_intent(obj, loopback_port_intents);

    Ok(serde_json::to_vec(&root).unwrap_or_else(|_| body.to_vec()))
}

fn is_dory_proxy_socket(source: &str) -> bool {
    source.ends_with("/.dory/dory.sock") || source.ends_with("/.dory/engine.sock")
}

fn normalize_dory_socket_mounts(hc: &mut serde_json::Map<String, Value>) {
    if let Some(binds) = hc.get_mut("Binds").and_then(Value::as_array_mut) {
        for bind in binds {
            let Some(raw) = bind.as_str() else { continue };
            let parts: Vec<&str> = raw.split(':').collect();
            if parts.len() < 2
                || parts[1] != "/var/run/docker.sock"
                || !is_dory_proxy_socket(parts[0])
            {
                continue;
            }
            let suffix = if parts.len() > 2 {
                format!(":{}", parts[2..].join(":"))
            } else {
                String::new()
            };
            *bind = Value::String(format!("/var/run/docker.sock:/var/run/docker.sock{suffix}"));
        }
    }

    if let Some(mounts) = hc.get_mut("Mounts").and_then(Value::as_array_mut) {
        for mount in mounts {
            let Some(map) = mount.as_object_mut() else {
                continue;
            };
            let mount_type = map.get("Type").and_then(Value::as_str);
            let source = map.get("Source").and_then(Value::as_str);
            let target = map
                .get("Target")
                .or_else(|| map.get("Destination"))
                .and_then(Value::as_str);
            if mount_type == Some("bind")
                && target == Some("/var/run/docker.sock")
                && source.is_some_and(is_dory_proxy_socket)
            {
                map.insert(
                    "Source".into(),
                    Value::String("/var/run/docker.sock".into()),
                );
            }
        }
    }
}

fn is_loopback(host_ip: &str) -> bool {
    matches!(host_ip, "127.0.0.1" | "::1" | "localhost") || host_ip.starts_with("127.")
}

fn loopback_intent(host_ip: &str) -> &'static str {
    if host_ip == "::1" {
        "ipv6"
    } else if host_ip == "localhost" {
        "localhost"
    } else {
        "ipv4"
    }
}

fn normalize_port_bindings(
    hc: &mut serde_json::Map<String, Value>,
) -> serde_json::Map<String, Value> {
    let mut intents = serde_json::Map::new();
    let Some(bindings) = hc.get_mut("PortBindings").and_then(Value::as_object_mut) else {
        return intents;
    };
    for (container_port, entry) in bindings {
        let Some(list) = entry.as_array_mut() else {
            continue;
        };
        for binding in list {
            let Some(map) = binding.as_object_mut() else {
                continue;
            };
            if let Some(Value::String(ip)) = map.get("HostIp") {
                if is_loopback(ip) {
                    // A single container port may have several host bindings. Choose the strictest
                    // family per requested host port. If both loopback families request the same
                    // dynamic/explicit port, `localhost` means expose both loopbacks, never LAN.
                    let intent = loopback_intent(ip);
                    let requested_host_port = map
                        .get("HostPort")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let per_host_port = intents
                        .entry(container_port.clone())
                        .or_insert_with(|| Value::Object(Default::default()));
                    if let Some(per_host_port) = per_host_port.as_object_mut() {
                        match per_host_port
                            .get(&requested_host_port)
                            .and_then(Value::as_str)
                        {
                            Some(existing) if existing != intent => {
                                per_host_port.insert(
                                    requested_host_port,
                                    Value::String("localhost".to_string()),
                                );
                            }
                            None => {
                                per_host_port
                                    .insert(requested_host_port, Value::String(intent.to_string()));
                            }
                            _ => {}
                        }
                    }
                    map.insert("HostIp".into(), Value::String(String::new()));
                }
            }
        }
    }
    intents
}

fn preserve_loopback_port_intent(
    root: &mut serde_json::Map<String, Value>,
    intents: serde_json::Map<String, Value>,
) {
    if intents.is_empty() {
        if let Some(labels) = root.get_mut("Labels").and_then(Value::as_object_mut) {
            labels.remove(LOOPBACK_PORT_INTENT_LABEL);
        }
        return;
    }
    let labels = root
        .entry("Labels")
        .or_insert_with(|| Value::Object(Default::default()));
    if !labels.is_object() {
        *labels = Value::Object(Default::default());
    }
    if let Some(labels) = labels.as_object_mut() {
        labels.insert(
            LOOPBACK_PORT_INTENT_LABEL.into(),
            Value::String(Value::Object(intents).to_string()),
        );
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

fn is_gpu_request(req: &Value) -> bool {
    if matches!(
        req.get("Driver").and_then(Value::as_str),
        Some("nvidia" | "cuda" | "dory")
    ) {
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
}

/// The daemon supplies admission; clients cannot select a host GPU runtime with an environment
/// variable. Only the render node is needed for Vulkan. Container images must supply compatible
/// Mesa userspace; mapping a DRM node does not implement NVIDIA/CUDA or install an ICD.
fn normalize_gpu_requests(
    hc: &mut serde_json::Map<String, Value>,
    supported: bool,
) -> Result<(), RewriteError> {
    let Some(requests) = hc.get("DeviceRequests").and_then(Value::as_array) else {
        return Ok(());
    };
    if !requests.iter().any(is_gpu_request) {
        return Ok(());
    }
    if !supported {
        return Err(RewriteError::GpuUnsupported);
    }
    for req in requests.iter().filter(|r| is_gpu_request(r)) {
        let driver = req.get("Driver").and_then(Value::as_str);
        if !matches!(driver, None | Some("" | "dory"))
            || req.get("Driver").is_some_and(|v| !v.is_null() && !v.is_string())
        {
            return Err(RewriteError::GpuRequestUnsupported("unsupported driver"));
        }
        let gpu_group = req
            .get("Capabilities")
            .and_then(Value::as_array)
            .is_some_and(|groups| {
                groups.iter().any(|g| {
                    g.as_array()
                        .is_some_and(|caps| caps.len() == 1 && caps[0] == "gpu")
                })
            });
        if !gpu_group {
            return Err(RewriteError::GpuRequestUnsupported(
                "unsupported capability set",
            ));
        }
        if req
            .get("Options")
            .is_some_and(|v| !v.is_null() && !v.as_object().is_some_and(|m| m.is_empty()))
        {
            return Err(RewriteError::GpuRequestUnsupported(
                "driver options are unsupported",
            ));
        }
        let ids = req.get("DeviceIDs");
        let has_ids =
            ids.is_some_and(|v| !v.is_null() && !v.as_array().is_some_and(|a| a.is_empty()));
        if has_ids {
            if ids != Some(&serde_json::json!(["0"])) || req.get("Count").is_some_and(|v| v != 0) {
                return Err(RewriteError::GpuRequestUnsupported(
                    "only device 0 is available",
                ));
            }
        } else if req
            .get("Count")
            .is_some_and(|v| !matches!(v.as_i64(), Some(-1 | 1)))
        {
            return Err(RewriteError::GpuRequestUnsupported(
                "only one GPU is available",
            ));
        }
    }
    let remaining: Vec<Value> = requests
        .iter()
        .filter(|r| !is_gpu_request(r))
        .cloned()
        .collect();
    const RENDER: &str = "/dev/dri/renderD128";
    let mut devices = match hc.get("Devices") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(devices)) => devices.clone(),
        _ => {
            return Err(RewriteError::GpuRequestUnsupported(
                "invalid device mappings",
            ))
        }
    };
    let mut mapped = false;
    for device in &devices {
        let target = device.get("PathInContainer").and_then(Value::as_str);
        if target == Some(RENDER) {
            if device.get("PathOnHost").and_then(Value::as_str) != Some(RENDER)
                || !matches!(
                    device.get("CgroupPermissions").and_then(Value::as_str),
                    Some("rw" | "rwm")
                )
            {
                return Err(RewriteError::GpuRequestUnsupported(
                    "conflicting render device mapping",
                ));
            }
            mapped = true;
        }
    }
    if !mapped {
        devices.push(serde_json::json!({
            "PathOnHost": RENDER, "PathInContainer": RENDER, "CgroupPermissions": "rw"
        }));
    }
    hc.insert("Devices".into(), Value::Array(devices));
    if remaining.is_empty() {
        hc.remove("DeviceRequests");
    } else {
        hc.insert("DeviceRequests".into(), Value::Array(remaining));
    }
    Ok(())
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
        let intent: Value =
            serde_json::from_str(out["Labels"][LOOPBACK_PORT_INTENT_LABEL].as_str().unwrap())
                .unwrap();
        assert_eq!(intent["80/tcp"]["8080"], "ipv4");
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
        assert!(out["Labels"][LOOPBACK_PORT_INTENT_LABEL].is_null());
    }

    #[test]
    fn dory_host_proxy_bind_is_rebound_to_guest_docker_socket() {
        let out = rewrite(
            json!({"HostConfig": {"Binds": [
                "/Users/test/.dory/engine.sock:/var/run/docker.sock:ro",
                "/Users/test/work:/workspace:rw"
            ]}}),
            false,
        )
        .unwrap();
        assert_eq!(
            out["HostConfig"]["Binds"],
            json!([
                "/var/run/docker.sock:/var/run/docker.sock:ro",
                "/Users/test/work:/workspace:rw"
            ])
        );
    }

    #[test]
    fn structured_dory_host_proxy_mount_is_rebound_but_other_mounts_are_unchanged() {
        let out = rewrite(
            json!({"HostConfig": {"Mounts": [
                {"Type":"bind", "Source":"/Users/test/.dory/dory.sock", "Target":"/var/run/docker.sock", "ReadOnly":true},
                {"Type":"bind", "Source":"/Users/test/.docker/run/docker.sock", "Target":"/var/run/docker.sock"},
                {"Type":"bind", "Source":"/Users/test/.dory/engine.sock", "Target":"/workspace"}
            ]}}),
            false,
        )
        .unwrap();
        assert_eq!(
            out["HostConfig"]["Mounts"][0]["Source"],
            "/var/run/docker.sock"
        );
        assert_eq!(
            out["HostConfig"]["Mounts"][1]["Source"],
            "/Users/test/.docker/run/docker.sock"
        );
        assert_eq!(
            out["HostConfig"]["Mounts"][2]["Source"],
            "/Users/test/.dory/engine.sock"
        );
    }

    #[test]
    fn loopback_intent_preserves_family_and_replaces_spoofed_internal_label() {
        let out = rewrite(
            json!({
                "Labels": {LOOPBACK_PORT_INTENT_LABEL: "{\"22/tcp\":{\"2222\":\"ipv4\"}}"},
                "HostConfig": {"PortBindings": {
                    "53/udp": [{"HostIp": "::1", "HostPort": "5353"}],
                    "80/tcp": [{"HostIp": "localhost", "HostPort": "8080"}]
                }}
            }),
            false,
        )
        .unwrap();
        let intent: Value =
            serde_json::from_str(out["Labels"][LOOPBACK_PORT_INTENT_LABEL].as_str().unwrap())
                .unwrap();
        assert_eq!(
            intent,
            json!({
                "53/udp": {"5353": "ipv6"},
                "80/tcp": {"8080": "localhost"}
            })
        );
    }

    #[test]
    fn spoofed_internal_label_is_removed_without_a_loopback_binding() {
        let out = rewrite(
            json!({"Labels": {LOOPBACK_PORT_INTENT_LABEL: "{\"80/tcp\":{\"8080\":\"ipv4\"}}"}, "HostConfig": {}}),
            false,
        )
        .unwrap();
        assert!(out["Labels"][LOOPBACK_PORT_INTENT_LABEL].is_null());
    }

    #[test]
    fn distinct_host_ports_keep_distinct_loopback_families() {
        let out = rewrite(
            json!({"HostConfig": {"PortBindings": {"80/tcp": [
                {"HostIp": "127.0.0.1", "HostPort": "8080"},
                {"HostIp": "::1", "HostPort": "8081"}
            ]}}}),
            false,
        )
        .unwrap();
        let intent: Value =
            serde_json::from_str(out["Labels"][LOOPBACK_PORT_INTENT_LABEL].as_str().unwrap())
                .unwrap();
        assert_eq!(intent["80/tcp"]["8080"], "ipv4");
        assert_eq!(intent["80/tcp"]["8081"], "ipv6");
    }

    #[test]
    fn mixed_families_on_one_dynamic_port_remain_both_loopbacks() {
        let out = rewrite(
            json!({"HostConfig": {"PortBindings": {"80/tcp": [
                {"HostIp": "127.0.0.1", "HostPort": ""},
                {"HostIp": "::1", "HostPort": ""}
            ]}}}),
            false,
        )
        .unwrap();
        let intent: Value =
            serde_json::from_str(out["Labels"][LOOPBACK_PORT_INTENT_LABEL].as_str().unwrap())
                .unwrap();
        assert_eq!(intent["80/tcp"][""], "localhost");
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

    /// The Go SDK marshals a nil HostConfig as `"HostConfig": null` (ContainerCreate with a nil
    /// host config — common in CI tools/testcontainers). A present-but-null parent must not skip
    /// every rewrite (adversarial review 2026-07-07, INVARIANT D).
    #[test]
    fn null_host_config_still_gets_rewrites() {
        let out = rewrite(json!({"Image": "alpine", "HostConfig": null}), false).unwrap();
        let hosts = out["HostConfig"]["ExtraHosts"].as_array().unwrap();
        assert!(hosts.contains(&json!("host.docker.internal:host-gateway")));
        assert!(hosts.contains(&json!("host.dory.internal:host-gateway")));
    }

    /// A GPU request inside an otherwise-present HostConfig is still gated even though the sibling
    /// coercion path exists — guards against the coercion accidentally masking the GPU check.
    #[test]
    fn gpu_still_gated_after_null_coercion_path() {
        let err = rewrite(
            json!({"HostConfig": {"DeviceRequests": [{"Capabilities": [["gpu"]]}]}}),
            false,
        );
        assert!(matches!(err, Err(RewriteError::GpuUnsupported)));
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
        let out = rewrite(body, true).unwrap();
        assert!(out["HostConfig"].get("DeviceRequests").is_none());
        assert_eq!(
            out["HostConfig"]["Devices"][0]["PathInContainer"],
            "/dev/dri/renderD128"
        );
        assert_eq!(out["HostConfig"]["Devices"][0]["CgroupPermissions"], "rw");
        assert!(out["HostConfig"].get("DeviceCgroupRules").is_none());
    }

    #[test]
    fn gpu_translation_preserves_other_requests_and_is_idempotent() {
        let other = json!({"Driver": "example-device", "Capabilities": [["example"]]});
        let body = json!({"HostConfig": {
            "DeviceRequests": [{"Count": -1, "Capabilities": [["gpu"]]}, other],
            "Devices": [{"PathOnHost": "/dev/example", "PathInContainer": "/dev/example", "CgroupPermissions": "r"}]
        }});
        let out = rewrite(body, true).unwrap();
        assert_eq!(out["HostConfig"]["DeviceRequests"], json!([other]));
        assert_eq!(out["HostConfig"]["Devices"].as_array().unwrap().len(), 2);
        assert_eq!(out["HostConfig"]["Devices"][0]["CgroupPermissions"], "r");
        assert_eq!(rewrite(out.clone(), true).unwrap(), out);
        let selected = rewrite(
            json!({"HostConfig": {"DeviceRequests": [{
                "Driver": "dory", "Count": 0, "DeviceIDs": ["0"], "Capabilities": [["gpu"]]
            }]}}),
            true,
        )
        .unwrap();
        assert_eq!(
            selected["HostConfig"]["Devices"][0]["PathOnHost"],
            "/dev/dri/renderD128"
        );
    }

    #[test]
    fn gpu_translation_rejects_unimplementable_requests_and_conflicting_mappings() {
        for request in [
            json!({"Driver": 42, "Capabilities": [["gpu"]]}),
            json!({"Driver": "nvidia", "Capabilities": [["gpu"]]}),
            json!({"Count": 2, "Capabilities": [["gpu"]]}),
            json!({"DeviceIDs": ["1"], "Capabilities": [["gpu"]]}),
            json!({"Capabilities": [["gpu", "cuda"]]}),
            json!({"Options": {"mode": "cuda"}, "Capabilities": [["gpu"]]}),
        ] {
            assert!(
                matches!(
                    rewrite(json!({"HostConfig": {"DeviceRequests": [request]}}), true),
                    Err(RewriteError::GpuRequestUnsupported(_))
                ),
                "{request}"
            );
        }
        assert!(matches!(
            rewrite(
                json!({"HostConfig": {
                    "DeviceRequests": [{"Capabilities": [["gpu"]]}],
                    "Devices": [{"PathOnHost": "/dev/other", "PathInContainer": "/dev/dri/renderD128", "CgroupPermissions": "rw"}]
                }}),
                true
            ),
            Err(RewriteError::GpuRequestUnsupported(_))
        ));
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
