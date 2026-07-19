/// An inert HTTP witness carried over gvproxy's private forward. It proves the guest Ethernet path
/// without exposing dockerd or another privileged control plane on the guest network.
public enum GuestDatapathCanary: Sendable {
    public static let port: UInt16 = 2_380

    public static func listener() -> String {
        let response = "HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\nOK"
        return "( while true; do printf '\(response)' | nc -l -p \(port) >/dev/null 2>&1 || true; done ) &"
    }
}
