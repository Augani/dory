//! Reconstructs the host-visible address in Docker container-inspect responses.
//!
//! Dory has to replace an explicitly requested loopback `HostIp` with an empty value before
//! forwarding a create request to the guest daemon: a port bound to the guest's loopback cannot
//! be reached by the host-side gvproxy forwarder. `create_rewrite` records that original intent in
//! a trusted internal label. Docker then reports the guest wildcard (`0.0.0.0`) from inspect even
//! though the effective macOS endpoint is still loopback-only. This module reverses only that
//! transport translation at the public Docker API boundary.

use serde_json::Value;

use crate::create_rewrite::LOOPBACK_PORT_INTENT_LABEL;

/// Rewrite both Docker inspect port-binding projections when Dory's create-time intent proves that
/// a wildcard is only the guest-side transport representation of an explicit loopback request.
/// Invalid or absent metadata is a no-op; a non-wildcard address is never overwritten.
pub fn rewrite_container_inspect_body(body: &[u8]) -> Option<Vec<u8>> {
    let mut root: Value = serde_json::from_slice(body).ok()?;
    let label = root
        .pointer("/Config/Labels")
        .and_then(Value::as_object)
        .and_then(|labels| labels.get(LOOPBACK_PORT_INTENT_LABEL))
        .and_then(Value::as_str)?;
    let intents: Value = serde_json::from_str(label).ok()?;
    let intents = intents.as_object()?;

    let mut changed = false;
    if let Some(bindings) = root.pointer_mut("/HostConfig/PortBindings") {
        changed |= rewrite_binding_projection(bindings, intents);
    }
    if let Some(bindings) = root.pointer_mut("/NetworkSettings/Ports") {
        changed |= rewrite_binding_projection(bindings, intents);
    }
    changed.then(|| serde_json::to_vec(&root).ok()).flatten()
}

fn rewrite_binding_projection(
    projection: &mut Value,
    intents: &serde_json::Map<String, Value>,
) -> bool {
    let Some(projection) = projection.as_object_mut() else {
        return false;
    };
    let mut changed = false;
    for (container_port, raw_bindings) in projection {
        let Some(per_host_port) = intents.get(container_port).and_then(Value::as_object) else {
            continue;
        };
        let Some(bindings) = raw_bindings.as_array_mut() else {
            continue;
        };
        for binding in bindings {
            let Some(binding) = binding.as_object_mut() else {
                continue;
            };
            let current_host = binding.get("HostIp").and_then(Value::as_str);
            if current_host.is_some_and(|host| !is_guest_wildcard(host)) {
                continue;
            }
            let resolved_host_port = binding
                .get("HostPort")
                .and_then(Value::as_str)
                .unwrap_or("");
            let Some(intent) = per_host_port
                .get(resolved_host_port)
                .or_else(|| per_host_port.get(""))
                .and_then(Value::as_str)
            else {
                continue;
            };
            let host = match intent {
                "ipv4" | "localhost" => "127.0.0.1",
                "ipv6" => "::1",
                _ => continue,
            };
            binding.insert("HostIp".into(), Value::String(host.into()));
            changed = true;
        }
    }
    changed
}

fn is_guest_wildcard(host: &str) -> bool {
    matches!(host.trim(), "" | "0.0.0.0" | "::" | "[::]")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rewrite(value: Value) -> Value {
        let body = serde_json::to_vec(&value).unwrap();
        serde_json::from_slice(&rewrite_container_inspect_body(&body).expect("body rewritten"))
            .unwrap()
    }

    #[test]
    fn restores_dynamic_ipv4_loopback_in_both_inspect_projections() {
        let create = crate::create_rewrite::rewrite_create_body(
            json!({"HostConfig": {"PortBindings": {"6443/tcp": [{
                "HostIp": "127.0.0.1", "HostPort": ""
            }]}}})
            .to_string()
            .as_bytes(),
            &crate::create_rewrite::RewriteOpts {
                gpu_supported: false,
            },
        )
        .unwrap();
        let create: Value = serde_json::from_slice(&create).unwrap();
        assert_eq!(
            create["HostConfig"]["PortBindings"]["6443/tcp"][0]["HostIp"],
            ""
        );
        let label = create["Labels"][LOOPBACK_PORT_INTENT_LABEL]
            .as_str()
            .unwrap();
        let out = rewrite(json!({
            "Config": {"Labels": {LOOPBACK_PORT_INTENT_LABEL: label}},
            "HostConfig": {"PortBindings": {
                "6443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "49173"}]
            }},
            "NetworkSettings": {"Ports": {
                "6443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "49173"}]
            }}
        }));

        assert_eq!(
            out["HostConfig"]["PortBindings"]["6443/tcp"][0]["HostIp"],
            "127.0.0.1"
        );
        assert_eq!(
            out["NetworkSettings"]["Ports"]["6443/tcp"][0]["HostIp"],
            "127.0.0.1"
        );
        assert_eq!(
            out["NetworkSettings"]["Ports"]["6443/tcp"][0]["HostPort"],
            "49173"
        );
    }

    #[test]
    fn matches_fixed_host_ports_and_preserves_distinct_families() {
        let label = json!({"443/tcp": {"8443": "ipv4", "9443": "ipv6"}}).to_string();
        let out = rewrite(json!({
            "Config": {"Labels": {LOOPBACK_PORT_INTENT_LABEL: label}},
            "HostConfig": {"PortBindings": {"443/tcp": [
                {"HostIp": "0.0.0.0", "HostPort": "8443"},
                {"HostIp": "::", "HostPort": "9443"}
            ]}}
        }));

        assert_eq!(
            out["HostConfig"]["PortBindings"]["443/tcp"][0]["HostIp"],
            "127.0.0.1"
        );
        assert_eq!(
            out["HostConfig"]["PortBindings"]["443/tcp"][1]["HostIp"],
            "::1"
        );
    }

    #[test]
    fn never_overwrites_a_non_wildcard_daemon_address() {
        let label = json!({"6443/tcp": {"49173": "ipv4"}}).to_string();
        let body = json!({
            "Config": {"Labels": {LOOPBACK_PORT_INTENT_LABEL: label}},
            "NetworkSettings": {"Ports": {"6443/tcp": [
                {"HostIp": "192.0.2.20", "HostPort": "49173"}
            ]}}
        });

        assert!(rewrite_container_inspect_body(&serde_json::to_vec(&body).unwrap()).is_none());
    }

    #[test]
    fn malformed_or_unrecognized_intent_is_a_no_op() {
        for label in ["not-json", r#"{"6443/tcp":{"":"lan"}}"#] {
            let body = json!({
                "Config": {"Labels": {LOOPBACK_PORT_INTENT_LABEL: label}},
                "NetworkSettings": {"Ports": {"6443/tcp": [
                    {"HostIp": "0.0.0.0", "HostPort": "49173"}
                ]}}
            });
            assert!(rewrite_container_inspect_body(&serde_json::to_vec(&body).unwrap()).is_none());
        }
    }
}
