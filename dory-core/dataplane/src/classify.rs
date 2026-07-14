//! Route a Docker request to one of four dispositions. Everything is passthrough now that the
//! backend is a real `dockerd`; the exceptions are the streaming/hijack endpoints (which must not be
//! buffered — buffering `build`/`load` reintroduces the `/wait`-before-`/start` deadlock) and
//! container create (which needs the compatibility rewrites).

use crate::http_head::RequestHead;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Disposition {
    /// Relay bytes verbatim to dockerd and back.
    Passthrough,
    /// Hand the raw connection to the half-close splice (attach/exec/build/load, or any Upgrade).
    Hijack,
    /// Rewrite the create body for shared-VM compatibility, then relay.
    CreateRewrite,
    /// Verify fixed macOS host ports before asking guest dockerd to start the container.
    ContainerStartPreflight,
}

pub fn classify(head: &RequestHead) -> Disposition {
    if head.is_upgrade {
        return Disposition::Hijack;
    }
    let (m, p) = (head.method.as_str(), head.path.as_str());
    if m == "POST" && p == "/containers/create" {
        return Disposition::CreateRewrite;
    }
    if m == "POST" && p.starts_with("/containers/") && p.ends_with("/start") {
        return Disposition::ContainerStartPreflight;
    }
    if p.ends_with("/attach") || p.ends_with("/attach/ws") {
        return Disposition::Hijack;
    }
    if p.starts_with("/exec/") && p.ends_with("/start") {
        return Disposition::Hijack;
    }
    // Image pull (`POST /images/create`) has a tiny fixed request and a streamed *response*. The
    // response pump is already byte-transparent, while keeping the request parser alive is vital:
    // Docker SDKs reuse that connection for later creates after the pull stream reaches EOF.
    if m == "POST" && (p == "/build" || p == "/images/load") {
        return Disposition::Hijack;
    }
    Disposition::Passthrough
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http_head::parse_head;

    fn disp(req: &str) -> Disposition {
        classify(&parse_head(req.as_bytes()).unwrap())
    }

    #[test]
    fn create_is_rewritten() {
        assert_eq!(
            disp("POST /v1.47/containers/create HTTP/1.1\r\n\r\n"),
            Disposition::CreateRewrite
        );
        assert_eq!(
            disp("POST /containers/create HTTP/1.1\r\n\r\n"),
            Disposition::CreateRewrite
        );
    }

    #[test]
    fn list_and_inspect_pass_through() {
        assert_eq!(
            disp("GET /v1.47/containers/json HTTP/1.1\r\n\r\n"),
            Disposition::Passthrough
        );
        assert_eq!(
            disp("GET /containers/abc/json HTTP/1.1\r\n\r\n"),
            Disposition::Passthrough
        );
    }

    #[test]
    fn container_start_requires_host_port_preflight() {
        assert_eq!(
            disp("POST /v1.47/containers/abc/start HTTP/1.1\r\n\r\n"),
            Disposition::ContainerStartPreflight
        );
        assert_eq!(
            disp("POST /containers/name/start HTTP/1.1\r\n\r\n"),
            Disposition::ContainerStartPreflight
        );
    }

    #[test]
    fn container_lifecycle_contract_preserves_routes_and_queries() {
        let passthrough = [
            ("POST", "/v1.47/containers/demo/stop?t=7"),
            ("POST", "/v1.47/containers/demo/kill?signal=SIGUSR1"),
            ("POST", "/v1.47/containers/demo/restart?t=5"),
            ("POST", "/v1.47/containers/demo/pause"),
            ("POST", "/v1.47/containers/demo/unpause"),
            ("POST", "/v1.47/containers/demo/wait?condition=next-exit"),
            ("POST", "/v1.47/containers/demo/exec"),
            (
                "GET",
                "/v1.47/containers/demo/logs?follow=1&stdout=1&stderr=1",
            ),
            ("GET", "/v1.47/containers/demo/stats?stream=1&one-shot=0"),
            ("DELETE", "/v1.47/containers/demo?force=1&v=1"),
        ];

        for (method, target) in passthrough {
            let request = format!("{method} {target} HTTP/1.1\r\nHost: d\r\n\r\n");
            let head = parse_head(request.as_bytes()).expect("parse lifecycle request");
            assert_eq!(head.raw_target, target);
            assert_eq!(classify(&head), Disposition::Passthrough, "{target}");
        }

        for target in [
            "/v1.47/containers/demo/attach?stdin=1&stdout=1&stream=1",
            "/v1.47/exec/exec-id/start",
        ] {
            let request = format!("POST {target} HTTP/1.1\r\nHost: d\r\n\r\n");
            let head = parse_head(request.as_bytes()).expect("parse stream request");
            assert_eq!(head.raw_target, target);
            assert_eq!(classify(&head), Disposition::Hijack, "{target}");
        }
    }

    #[test]
    fn streaming_and_hijack_endpoints() {
        assert_eq!(
            disp("POST /containers/abc/attach HTTP/1.1\r\n\r\n"),
            Disposition::Hijack
        );
        assert_eq!(
            disp("POST /exec/xyz/start HTTP/1.1\r\n\r\n"),
            Disposition::Hijack
        );
        assert_eq!(
            disp("POST /v1.47/build HTTP/1.1\r\n\r\n"),
            Disposition::Hijack
        );
        assert_eq!(
            disp("POST /images/create?fromImage=alpine HTTP/1.1\r\n\r\n"),
            Disposition::Passthrough
        );
    }

    #[test]
    fn upgrade_always_hijacks() {
        let d = disp("GET /events HTTP/1.1\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n");
        assert_eq!(d, Disposition::Hijack);
    }
}
