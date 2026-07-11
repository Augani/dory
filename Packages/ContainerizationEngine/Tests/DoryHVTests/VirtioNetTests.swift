import Darwin
import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtioNetTests {
    @Test func receiveFrameWaitsForGuestBufferAndDrainsOnReceiveKick() throws {
        // sockaddr_un paths are capped at 103 bytes on Darwin; /var/folders/.../T is often already
        // long enough that a descriptive UUID path overflows it.
        let directory = "/tmp/dvn-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let proxyPath = directory + "/proxy.sock"
        let devicePath = directory + "/device.sock"
        let proxyFD = try bindUnixDatagram(path: proxyPath)
        defer { close(proxyFD) }

        let device = try VirtioNet(socketPath: devicePath, remotePath: proxyPath)
        var magic = [UInt8](repeating: 0, count: 4)
        #expect(recv(proxyFD, &magic, magic.count, 0) == 4)
        #expect(magic == Array("VFKT".utf8))

        let guestBase: UInt64 = 0x8000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let descriptorTable = guestBase + 0x1_0000
        let availableRing = guestBase + 0x1_1000
        let usedRing = guestBase + 0x1_2000
        let receiveBuffer = guestBase + 0x1_3000
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(0), at: availableRing + 2) // no RX buffers yet
        try memory.write(UInt16(0), at: usedRing + 2)
        device.deviceReady(transport: transport)

        let ethernetFrame = Array(0..<64).map(UInt8.init)
        try sendDatagram(ethernetFrame, from: proxyFD, to: devicePath)
        #expect(waitUntil { device.statistics.receiveDeferred == 1 })
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == 0)
        #expect(device.statistics.receiveDrops == 0)

        // Linux replenishes receive buffers and notifies queue 0. The saved datagram must now be
        // delivered intact instead of having been lost during the temporary empty-ring window.
        try memory.write(receiveBuffer, at: descriptorTable)
        try memory.write(UInt32(2048), at: descriptorTable + 8)
        try memory.write(UInt16(2), at: descriptorTable + 12) // VIRTQ_DESC_F_WRITE
        try memory.write(UInt16(0), at: descriptorTable + 14)
        try memory.write(UInt16(0), at: availableRing + 4)
        try memory.write(UInt16(1), at: availableRing + 2)
        device.handleKick(queue: 0, transport: transport)

        #expect(waitUntil { (try? memory.read(UInt16.self, at: usedRing + 2)) == 1 })
        let written = Int(try memory.read(UInt32.self, at: usedRing + 8))
        #expect(written == 12 + ethernetFrame.count)
        let packet = try memory.readBytes(at: receiveBuffer, count: written)
        #expect(packet[0..<10].allSatisfy { $0 == 0 })
        #expect(Array(packet[10..<12]) == [1, 0])
        #expect(Array(packet.dropFirst(12)) == ethernetFrame)
        #expect(device.statistics.receivePackets == 1)
        #expect(device.statistics.receiveBytes == UInt64(ethernetFrame.count))
        #expect(device.statistics.receiveTruncations == 0)
    }

    @Test func rejectsUnixDatagramPathsThatWouldBeSilentlyTruncated() throws {
        let tooLong = "/tmp/" + String(repeating: "x", count: 200)
        #expect(throws: VMError.self) {
            _ = try VirtioNet(socketPath: tooLong, remotePath: "/tmp/unused.sock")
        }
    }

    @Test func saturatedTransmitSocketDropsWithoutPinningTheTransportLock() throws {
        let directory = "/tmp/dvn-tx-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let proxyPath = directory + "/proxy.sock"
        let devicePath = directory + "/device.sock"
        let proxyFD = try bindUnixDatagram(path: proxyPath, receiveBufferBytes: 1_024)
        defer { close(proxyFD) }

        let device = try VirtioNet(socketPath: devicePath, remotePath: proxyPath)
        #expect(device.isSocketNonblockingForTesting)

        let guestBase: UInt64 = 0x9000_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: device,
            memory: memory
        ) {}
        let descriptorTable = guestBase + 0x1_0000
        let availableRing = guestBase + 0x1_1000
        let usedRing = guestBase + 0x1_2000
        let frameBase = guestBase + 0x2_0000
        let frameCount: UInt16 = 64
        let frameStride: UInt64 = 1_024
        let frame = [UInt8](repeating: 0, count: 12) + [UInt8](repeating: 0xA5, count: 512)

        transport.queues[1].configure(
            size: frameCount,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[1].setReady(true)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(frameCount, at: availableRing + 2)
        try memory.write(UInt16(0), at: usedRing + 2)
        for index in 0..<frameCount {
            let descriptor = descriptorTable + UInt64(index) * 16
            let frameAddress = frameBase + UInt64(index) * frameStride
            try memory.write(frame, at: frameAddress)
            try memory.write(frameAddress, at: descriptor)
            try memory.write(UInt32(frame.count), at: descriptor + 8)
            try memory.write(UInt16(0), at: descriptor + 12)
            try memory.write(UInt16(0), at: descriptor + 14)
            try memory.write(index, at: availableRing + 4 + UInt64(index) * 2)
        }

        // Do not read from proxyFD: its deliberately tiny receive queue must saturate. In the
        // regressed implementation send() could wait while transport.write held the register lock.
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            transport.write(offset: 0x050, value: 1, width: 4)
            completed.signal()
        }
        let completionResult = completed.wait(timeout: .now() + 2)
        #expect(completionResult == .success)
        guard completionResult == .success else { return }
        #expect(try memory.read(UInt16.self, at: usedRing + 2) == frameCount)

        let statistics = device.statistics
        #expect(statistics.transmitPackets + statistics.transmitDrops == UInt64(frameCount))
        #expect(statistics.transmitDrops > 0)
        #expect(statistics.transmitBytes == statistics.transmitPackets * 512)

        // A completed kick must also have released the transport lock for subsequent MMIO.
        #expect(transport.read(offset: 0x008, width: 4) == UInt64(device.deviceID))
    }

    private func bindUnixDatagram(path: String, receiveBufferBytes: Int32? = nil) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("test socket failed: errno \(errno)")
        }
        if var receiveBufferBytes {
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBufferBytes,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                close(descriptor)
                throw VMError.invalidConfiguration("test receive buffer failed: errno \(errno)")
            }
        }
        unlink(path)
        var address = unixAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw VMError.invalidConfiguration("test bind failed: errno \(errno)")
        }
        return descriptor
    }

    private func sendDatagram(_ bytes: [UInt8], from descriptor: Int32, to path: String) throws {
        var address = unixAddress(path)
        let sent = bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        descriptor,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        guard sent == bytes.count else {
            throw VMError.invalidConfiguration("test send failed: errno \(errno)")
        }
    }

    private func unixAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            precondition(path.utf8.count < destination.count)
            destination.copyBytes(from: path.utf8)
        }
        return address
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            usleep(5_000)
        }
        return predicate()
    }
}
