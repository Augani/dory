import Testing
import Foundation
@testable import Dory

struct DockerImageOpsTests {
    @Test func commitPathEncodesQuery() {
        let path = DockerImageOps.commitPath(container: "dory-machine-dev", repo: "dory-snapshot/dev", tag: "s1700000000")
        #expect(path == "/commit?container=dory-machine-dev&repo=dory-snapshot/dev&tag=s1700000000")
    }
}
