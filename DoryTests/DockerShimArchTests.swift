import Testing
@testable import Dory

@Suite struct DockerShimArchTests {
    @Test func versionArchMatchesBuildArch() {
        #if arch(arm64)
        #expect(DockerShim.hostDockerArch() == "arm64")
        #expect(DockerShim.hostKernelArch() == "aarch64")
        #else
        #expect(DockerShim.hostDockerArch() == "amd64")
        #expect(DockerShim.hostKernelArch() == "x86_64")
        #endif
    }
}
