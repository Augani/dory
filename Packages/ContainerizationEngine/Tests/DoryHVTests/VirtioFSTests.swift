import Foundation
import Testing
@testable import DoryHV

struct VirtioFSTests {
    @Test func exposesVirtioFSDeviceIdentityAndQueues() throws {
        let root = try TestVirtioFSRoot()
        let fs = try VirtioFS(tag: "home", hostFS: HostFS(rootPath: root.url.path))

        #expect(fs.deviceID == 26)
        #expect(fs.queueCount == 2)
        #expect(fs.deviceFeatures & VirtioFS.notificationFeature == 0)
    }

    @Test func configSpaceContainsPaddedTagAndOneRequestQueue() throws {
        let root = try TestVirtioFSRoot()
        let fs = try VirtioFS(tag: "home", hostFS: HostFS(rootPath: root.url.path))
        let config = fs.configSpace

        #expect(config.count == 40)
        #expect(String(decoding: config[0..<4], as: UTF8.self) == "home")
        #expect(config[4..<VirtioFS.tagByteCount].allSatisfy { $0 == 0 })
        #expect(config[36..<40].elementsEqual([1, 0, 0, 0]))
    }

    @Test func tagMustFitVirtioConfigField() throws {
        let root = try TestVirtioFSRoot()
        let host = try HostFS(rootPath: root.url.path)

        #expect(throws: VirtioFSError.invalidTag("")) {
            _ = try VirtioFS(tag: "", hostFS: host)
        }
        #expect(throws: VirtioFSError.invalidTag(String(repeating: "x", count: 36))) {
            _ = try VirtioFS(tag: String(repeating: "x", count: 36), hostFS: host)
        }
    }

    @Test func daxConfigurationIsExplicitAndPageAligned() throws {
        let root = try TestVirtioFSRoot()
        let host = try HostFS(rootPath: root.url.path)

        let config = VirtioFSDaxConfiguration(guestBase: 0x1_0000_0000, length: 0x20_0000)
        let fs = try VirtioFS(tag: "home", hostFS: host, daxConfiguration: config)

        #expect(fs.daxConfiguration == config)
        #expect(fs.sharedMemoryRegions == [
            VirtioSharedMemoryRegion(id: 0, guestBase: 0x1_0000_0000, length: 0x20_0000),
        ])
        #expect(throws: VirtioFSError.invalidDaxWindow) {
            _ = try VirtioFS(tag: "bad", hostFS: host, daxConfiguration: VirtioFSDaxConfiguration(guestBase: 0x1001, length: 0x2000))
        }
    }
}

private final class TestVirtioFSRoot {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-virtiofs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
