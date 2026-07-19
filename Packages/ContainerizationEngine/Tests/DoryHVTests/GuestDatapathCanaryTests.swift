import DoryHV
import Testing

struct GuestDatapathCanaryTests {
    @Test func canaryIsInertAndDoesNotReuseDockerTCPPort() {
        #expect(GuestDatapathCanary.port == 2_380)
        #expect(GuestDatapathCanary.listener().contains("HTTP/1.1 200 OK"))
        #expect(!GuestDatapathCanary.listener().contains("2375"))
        #expect(!GuestDatapathCanary.listener().contains("dockerd"))
    }
}
