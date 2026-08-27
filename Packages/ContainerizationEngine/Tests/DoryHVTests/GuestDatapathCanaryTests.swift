import DoryHV
import Testing

struct GuestDatapathCanaryTests {
    @Test func canaryIsInertAndDoesNotReuseDockerTCPPort() {
        #expect(GuestDatapathCanary.port == 2_380)
        #expect(GuestDatapathCanary.environmentKey == "DORY_DATAPATH_CANARY_PORT")
        #expect(GuestDatapathCanary.agentEnvironmentAssignment() == "DORY_DATAPATH_CANARY_PORT=2380")
        #expect(!GuestDatapathCanary.agentEnvironmentAssignment().contains("2375"))
        #expect(!GuestDatapathCanary.agentEnvironmentAssignment().contains("dockerd"))
    }
}
