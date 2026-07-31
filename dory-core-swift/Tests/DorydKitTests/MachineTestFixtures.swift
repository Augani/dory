import Foundation

let doryTestKernelPath: String = makeMachineTestArtifact(name: "kernel")
let doryTestRootfsPath: String = makeMachineTestArtifact(name: "rootfs.ext4")
#if arch(arm64)
let doryTestGuestArchitecture = "arm64"
#elseif arch(x86_64)
let doryTestGuestArchitecture = "amd64"
#else
let doryTestGuestArchitecture = "unsupported"
#endif

private let machineTestCleanupRegistration = atexit {
    unlink(machineTestArtifactPath(name: "kernel"))
    unlink(machineTestArtifactPath(name: "rootfs.ext4"))
}

private func makeMachineTestArtifact(name: String) -> String {
    _ = machineTestCleanupRegistration
    let path = machineTestArtifactPath(name: name)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(
            atPath: path,
            contents: Data("dory machine test artifact: \(name)".utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }
    return path
}

private func machineTestArtifactPath(name: String) -> String {
    "/tmp/dory-core-machine-tests-\(getpid())-\(name)"
}
