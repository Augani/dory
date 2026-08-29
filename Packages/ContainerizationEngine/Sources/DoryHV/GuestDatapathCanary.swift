/// An inert HTTP witness carried over gvproxy's private forward. It proves the guest Ethernet path
/// without exposing dockerd or another privileged control plane on the guest network.
public enum GuestDatapathCanary: Sendable {
    public static let port: UInt16 = 2_380
    public static let environmentKey = "DORY_DATAPATH_CANARY_PORT"
    public static let requiredBootConfigurationKernelArgument = "dory.config=required"

    public static func agentEnvironmentAssignment() -> String {
        "\(environmentKey)=\(port)"
    }
}
