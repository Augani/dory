/// Builds the isolated gvproxy command line used by persistent desktop VMs.
///
/// Desktop control and shell access travel over dedicated per-machine vsock bridges. Keeping
/// gvproxy on private Unix sockets—and explicitly disabling its legacy SSH forward—prevents one
/// desktop from claiming a host-global port needed by another desktop or by its own restart.
package enum GVProxyDesktopLaunchPlan {
    package static let hostOnlyConfigurationYAML = """
    stack:
      connectivity: host-only

    """

    /// Pins gvproxy's deterministic guest lease to the MAC persisted in the resolved plan.
    /// Without this binding an adapter could expose one MAC while DHCP authority retained the
    /// historical global default.
    package static func configurationYAML(hostOnly: Bool, guestMAC: String) -> String {
        let connectivity = hostOnly ? "  connectivity: host-only\n" : ""
        return """
        stack:
        \(connectivity)  dhcpStaticLeases:
            192.168.127.2: \(guestMAC)

        """
    }

    package static func arguments(
        mtu: Int,
        datapathSocket: String,
        apiSocket: String,
        configurationPath: String? = nil
    ) -> [String] {
        var arguments = [
            "-mtu", String(mtu),
            "-listen-vfkit", "unixgram://\(datapathSocket)",
            "-listen", "unix://\(apiSocket)",
            "-ssh-port", "-1",
        ]
        if let configurationPath {
            arguments.append(contentsOf: ["-config", configurationPath])
        }
        return arguments
    }
}
