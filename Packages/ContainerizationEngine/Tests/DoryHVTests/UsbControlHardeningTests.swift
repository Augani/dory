import Darwin
import DoryVMContracts
import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized)
struct UsbControlSocketHardeningTests {
    @Test func descriptorShutdownCannotRacePastOwnerClose() {
        let shutdownEntered = DispatchSemaphore(value: 0)
        let allowShutdown = DispatchSemaphore(value: 0)
        let shutdownFinished = DispatchSemaphore(value: 0)
        let closeAttempted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let calls = UsbLockedStrings()
        let lifetime = UsbControlDescriptorLifetime(
            descriptor: 42,
            shutdownOperation: { descriptor in
                calls.append("shutdown:\(descriptor)")
                shutdownEntered.signal()
                allowShutdown.wait()
            },
            closeOperation: { descriptor in
                calls.append("close:\(descriptor)")
                closeFinished.signal()
            }
        )

        DispatchQueue.global().async {
            lifetime.requestShutdown()
            shutdownFinished.signal()
        }
        #expect(shutdownEntered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async {
            closeAttempted.signal()
            lifetime.closeByOwner()
        }
        #expect(closeAttempted.wait(timeout: .now() + 1) == .success)
        #expect(closeFinished.wait(timeout: .now() + 0.05) == .timedOut)
        allowShutdown.signal()
        #expect(shutdownFinished.wait(timeout: .now() + 1) == .success)
        #expect(closeFinished.wait(timeout: .now() + 1) == .success)
        #expect(calls.values == ["shutdown:42", "close:42"])

        lifetime.requestShutdown()
        lifetime.closeByOwner()
        #expect(calls.values == ["shutdown:42", "close:42"])
    }

    @Test func silentClientCannotStarveLaterRequest() throws {
        try withTemporarySocketPath("silent") { path in
            let server = UsbControlServer(
                path: path,
                handler: makeControlHandler(),
                maximumSessions: 2,
                frameTimeout: 0.1,
                expectedPeerUID: geteuid(),
                peerUIDResolver: UsbControlSocketIO.peerUID
            )
            try server.start()
            defer { _ = server.stop() }

            let silent = try connectRawUnixSocket(path)
            defer { close(silent) }
            #expect(waitUntil { server.activeSessionCount == 1 })

            let response = try sendRawControlRequest(
                .attach(busID: try DoryUSBControlV1.BusID("3-2"), mode: .userAuthorized),
                path: path,
                timeout: 2
            )
            guard case .attachSuccess(let attachment) = response else {
                Issue.record("shared USB attach request did not produce attachSuccess: \(response)")
                return
            }
            #expect(attachment.port == 0)
        }
    }

    @Test func maximumFrameRequiresNewlineAndRejectsOversizeOrTrailingBytes() throws {
        var oversized = [UInt8](
            repeating: 0x61,
            count: UsbControlSocketIO.maximumFrameBytes + 1
        )
        oversized.append(0x0a)
        let oversizedReader = UsbInjectedReader(oversized)
        #expect(throws: UsbControlServerError.frameTooLarge(
            limit: UsbControlSocketIO.maximumFrameBytes
        )) {
            _ = try UsbControlSocketIO.readFrame(
                descriptor: -1,
                deadline: ProcessInfo.processInfo.systemUptime + 1,
                readOperation: oversizedReader.read
            )
        }

        let incomplete = Array("{}".utf8)
        let incompleteReader = UsbInjectedReader(incomplete)
        #expect(throws: UsbControlServerError.incompleteFrame) {
            _ = try UsbControlSocketIO.readFrame(
                descriptor: -1,
                deadline: ProcessInfo.processInfo.systemUptime + 1,
                readOperation: incompleteReader.read
            )
        }

        let trailing = Array("{}\nextra".utf8)
        let trailingReader = UsbInjectedReader(trailing)
        #expect(throws: UsbControlServerError.unexpectedTrailingBytes) {
            _ = try UsbControlSocketIO.readFrame(
                descriptor: -1,
                deadline: ProcessInfo.processInfo.systemUptime + 1,
                readOperation: trailingReader.read
            )
        }
    }

    @Test func framingHelpersHandleInjectedPartialReadsAndWrites() throws {
        let source = Array("{\"ok\":true}\n".utf8)
        var sourceOffset = 0
        let frame = try UsbControlSocketIO.readFrame(
            descriptor: -1,
            deadline: ProcessInfo.processInfo.systemUptime + 1,
            readOperation: { _, destination, requested in
                let count = min(2, requested, source.count - sourceOffset)
                guard count > 0 else { return 0 }
                source.withUnsafeBytes { bytes in
                    destination?.copyMemory(
                        from: bytes.baseAddress!.advanced(by: sourceOffset),
                        byteCount: count
                    )
                }
                sourceOffset += count
                return count
            }
        )
        #expect(frame == Data(source.dropLast()))

        let payload = Data("partial-write".utf8)
        var written = Data()
        try UsbControlSocketIO.writeAll(
            descriptor: -1,
            bytes: payload,
            deadline: ProcessInfo.processInfo.systemUptime + 1,
            writeOperation: { _, source, requested in
                let count = min(3, requested)
                if let source, count > 0 {
                    written.append(source.assumingMemoryBound(to: UInt8.self), count: count)
                }
                return count
            }
        )
        #expect(written == payload)
    }

    @Test func wholeFrameDeadlineIncludesProgressingReadAndWriteOperations() throws {
        #expect(throws: UsbControlServerError.timedOut(operation: "request frame")) {
            _ = try UsbControlSocketIO.readFrame(
                descriptor: -1,
                deadline: ProcessInfo.processInfo.systemUptime + 0.01,
                readOperation: { _, destination, requested in
                    usleep(20_000)
                    guard requested >= 2 else { return 0 }
                    destination?.assumingMemoryBound(to: UInt8.self)[0] = 0x7b
                    destination?.assumingMemoryBound(to: UInt8.self)[1] = 0x0a
                    return 2
                }
            )
        }

        #expect(throws: UsbControlServerError.timedOut(operation: "response frame")) {
            try UsbControlSocketIO.writeAll(
                descriptor: -1,
                bytes: Data("response".utf8),
                deadline: ProcessInfo.processInfo.systemUptime + 0.01,
                writeOperation: { _, _, requested in
                    usleep(20_000)
                    return min(1, requested)
                }
            )
        }
    }

    @Test func serverUsesSharedExactWireGrammarAndTypedRejectedFailures() throws {
        try withTemporarySocketPath("shared-wire") { path in
            let server = UsbControlServer(path: path, handler: makeControlHandler())
            try server.start()
            defer { _ = server.stop() }

            let busID = try DoryUSBControlV1.BusID("3-2")
            let attached = try sendRawControlRequest(
                .attach(busID: busID, mode: .userAuthorized),
                path: path,
                timeout: 2
            )
            guard case .attachSuccess(let attachment) = attached else {
                Issue.record("shared attach variant was not returned: \(attached)")
                return
            }
            #expect(attachment.vsockPort == DoryUSBControlV1.usbipVsockPort)

            let detached = try sendRawControlRequest(
                .detach(busID: busID),
                path: path,
                timeout: 2
            )
            #expect(detached == .detachSuccess)

            let malformed = [
                #"{"cmd":"attach","busid":"3-2"}"#,
                #"{"cmd":"attach","busid":"3-2","mode":"userAuthorized","extra":true}"#,
                #"{"cmd":"detach","busid":"3-2","mode":"userAuthorized"}"#,
                #"{"cmd":"attach","cmd":"detach","busid":"3-2","mode":"userAuthorized"}"#,
            ]
            for json in malformed {
                let response = try sendRawControlFrame(
                    framedRawJSON(json),
                    path: path,
                    timeout: 2
                )
                guard case .failure(let disposition, _) = response else {
                    Issue.record("malformed shared request was not rejected: \(json)")
                    continue
                }
                #expect(disposition == .rejected)
            }
        }
    }

    @Test func serverSanitizesFailuresIntoTheSharedPrintableBound() throws {
        try withTemporarySocketPath("failure-bound") { path in
            let handler = UsbControlHandler(
                manager: UsbipManager(),
                ensureSupported: { throw UsbHostileControlError() },
                openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
                notifyAttach: { _ in },
                notifyDetach: { _ in }
            )
            let server = UsbControlServer(path: path, handler: handler)
            try server.start()
            defer { _ = server.stop() }

            let response = try sendRawControlRequest(
                .attach(
                    busID: try DoryUSBControlV1.BusID("3-2"),
                    mode: .userAuthorized
                ),
                path: path,
                timeout: 2
            )
            guard case .failure(let disposition, let failure) = response else {
                Issue.record("hostile diagnostic did not return a shared failure")
                return
            }
            #expect(disposition == .rejected)
            #expect(failure.utf8.count <= DoryUSBControlV1.maximumFailureMessageUTF8Bytes)
            #expect(failure.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) })
        }
    }

    @Test func stopRetainsReplacementEndpointIdentity() throws {
        try withTemporarySocketPath("replacement") { path in
            let server = UsbControlServer(path: path, handler: makeControlHandler())
            try server.start()
            #expect(unlink(path) == 0)
            let replacement = try makeRawUnixListener(path)
            defer {
                close(replacement)
                _ = unlink(path)
            }
            var before = stat()
            #expect(lstat(path, &before) == 0)

            #expect(server.stop())
            var after = stat()
            #expect(lstat(path, &after) == 0)
            #expect(after.st_dev == before.st_dev)
            #expect(after.st_ino == before.st_ino)
        }
    }

    @Test func staleProbeCannotUnlinkAReplacementEndpoint() throws {
        try withTemporarySocketPath("stale-replacement") { path in
            let stale = try makeRawUnixListener(path)
            close(stale)
            let replacement = UsbLockedDescriptor()
            let server = UsbControlServer(
                path: path,
                handler: makeControlHandler(),
                maximumSessions: 1,
                frameTimeout: 1,
                expectedPeerUID: geteuid(),
                peerUIDResolver: UsbControlSocketIO.peerUID,
                beforeStaleEndpointUnlinkValidation: {
                    guard unlink(path) == 0 else {
                        throw UsbControlServerError.systemCall(
                            operation: "replace stale test endpoint",
                            code: errno
                        )
                    }
                    replacement.store(try makeRawUnixListener(path))
                }
            )

            #expect(throws: UsbControlServerError.untrustedEndpoint(path)) {
                try server.start()
            }
            let descriptor = try #require(replacement.value)
            defer {
                close(descriptor)
                _ = unlink(path)
            }
            var retained = stat()
            #expect(lstat(path, &retained) == 0)
            #expect(retained.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK))
        }
    }

    @Test func rejectsNoncanonicalAndUntrustedParentDirectories() throws {
        let root = "/tmp/dory-usb-parent-policy-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        #expect(chmod(root, 0o700) == 0)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let noncanonical = UsbControlServer(
            path: root + "/nested/../control.sock",
            handler: makeControlHandler()
        )
        #expect(throws: UsbControlServerError.invalidPath(root + "/nested/../control.sock")) {
            try noncanonical.start()
        }

        let writableParent = root + "/writable"
        try FileManager.default.createDirectory(atPath: writableParent, withIntermediateDirectories: false)
        #expect(chmod(writableParent, 0o777) == 0)
        let writableServer = UsbControlServer(
            path: writableParent + "/control.sock",
            handler: makeControlHandler()
        )
        #expect(throws: UsbControlServerError.untrustedParentDirectory(writableParent)) {
            try writableServer.start()
        }

        let regularParent = root + "/regular"
        try Data("not-a-directory".utf8).write(to: URL(fileURLWithPath: regularParent))
        let regularServer = UsbControlServer(
            path: regularParent + "/control.sock",
            handler: makeControlHandler()
        )
        #expect(throws: UsbControlServerError.untrustedParentDirectory(regularParent)) {
            try regularServer.start()
        }

        let symlinkTarget = root + "/target"
        let symlinkParent = root + "/link"
        try FileManager.default.createDirectory(atPath: symlinkTarget, withIntermediateDirectories: false)
        #expect(chmod(symlinkTarget, 0o700) == 0)
        #expect(symlink(symlinkTarget, symlinkParent) == 0)
        let symlinkServer = UsbControlServer(
            path: symlinkParent + "/control.sock",
            handler: makeControlHandler()
        )
        #expect(throws: UsbControlServerError.untrustedParentDirectory(symlinkParent)) {
            try symlinkServer.start()
        }
    }

    @Test func parentReplacementAfterBindIsPreservedAndFailsClosed() throws {
        let parent = "/tmp/dory-usb-parent-replace-\(getpid())-\(UUID().uuidString)"
        let originalParent = parent + ".original"
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        #expect(chmod(parent, 0o700) == 0)
        defer {
            try? FileManager.default.removeItem(atPath: parent)
            try? FileManager.default.removeItem(atPath: originalParent)
        }
        let sentinel = Data("replacement-parent".utf8)
        let server = UsbControlServer(
            path: parent + "/control.sock",
            handler: makeControlHandler(),
            maximumSessions: 1,
            frameTimeout: 0.2,
            expectedPeerUID: geteuid(),
            peerUIDResolver: { _ in geteuid() },
            afterListenerBindValidation: {
                guard rename(parent, originalParent) == 0 else {
                    throw UsbControlServerError.systemCall(
                        operation: "replace USB control parent",
                        code: errno
                    )
                }
                try FileManager.default.createDirectory(
                    atPath: parent,
                    withIntermediateDirectories: false
                )
                guard chmod(parent, 0o700) == 0 else {
                    throw UsbControlServerError.systemCall(
                        operation: "secure replacement USB control parent",
                        code: errno
                    )
                }
                try sentinel.write(to: URL(fileURLWithPath: parent + "/sentinel"))
            }
        )

        #expect(throws: UsbControlServerError.untrustedParentDirectory(parent)) {
            try server.start()
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: parent + "/sentinel")) == sentinel)
        #expect(FileManager.default.fileExists(atPath: originalParent + "/control.sock"))
        #expect(!FileManager.default.fileExists(atPath: parent + "/control.sock"))
    }

    @Test func duplicateStartFailsAndStoppedEndpointCanRebind() throws {
        try withTemporarySocketPath("rebind") { path in
            let first = UsbControlServer(path: path, handler: makeControlHandler())
            try first.start()
            #expect(throws: UsbControlServerError.alreadyStarted) { try first.start() }
            #expect(first.stop())

            let second = UsbControlServer(path: path, handler: makeControlHandler())
            try second.start()
            #expect(second.stop())
        }
    }

    @Test func peerUIDSeamRejectsBeforeDecodingRequest() throws {
        try withTemporarySocketPath("peer") { path in
            let logs = UsbLockedStrings()
            let server = UsbControlServer(
                path: path,
                handler: makeControlHandler(),
                maximumSessions: 2,
                frameTimeout: 0.2,
                expectedPeerUID: geteuid(),
                peerUIDResolver: { _ in geteuid() &+ 1 },
                log: { logs.append($0) }
            )
            try server.start()
            defer { _ = server.stop() }
            let client = try connectRawUnixSocket(path)
            defer { close(client) }
            try writeRaw(client, framedRawJSON(#"{"cmd":"attach","busid":"3-2"}"#))
            #expect(waitUntil { logs.values.contains { $0.contains("UID mismatch") } })
        }
    }

    @Test func sessionCapRejectsWithoutBlockingStop() throws {
        try withTemporarySocketPath("cap") { path in
            let server = UsbControlServer(
                path: path,
                handler: makeControlHandler(),
                maximumSessions: 1,
                frameTimeout: 2,
                expectedPeerUID: geteuid(),
                peerUIDResolver: UsbControlSocketIO.peerUID
            )
            try server.start()
            let first = try connectRawUnixSocket(path)
            defer { close(first) }
            #expect(waitUntil { server.activeSessionCount == 1 })
            let second = try connectRawUnixSocket(path)
            defer { close(second) }
            #expect(waitUntil { server.rejectedSessionCount == 1 })
            #expect(server.activeSessionCount == 1)
            #expect(server.stop(timeout: 1))
        }
    }

    @Test func unknownWireModeIsRejectedBySharedCodecBeforeOpeningHardware() throws {
        try withTemporarySocketPath("mode") { path in
            let opens = UsbLockedCounter()
            let handler = UsbControlHandler(
                manager: UsbipManager(),
                openDevice: { busID, _ in
                    opens.increment()
                    return UsbControlTestDevice(busID: busID)
                },
                notifyAttach: { _ in },
                notifyDetach: { _ in }
            )
            let server = UsbControlServer(path: path, handler: handler)
            try server.start()
            defer { _ = server.stop() }

            let response = try sendRawControlFrame(
                framedRawJSON(#"{"cmd":"attach","busid":"3-2","mode":"surprise"}"#),
                path: path,
                timeout: 2
            )
            guard case .failure(let disposition, _) = response else {
                Issue.record("unknown mode did not return a shared failure")
                return
            }
            #expect(disposition == .rejected)
            #expect(opens.value == 0)
        }
    }

    @Test func nonUserAuthorizedWireModeIsRejectedBeforeOpeningHardware() throws {
        try withTemporarySocketPath("mode-policy") { path in
            let opens = UsbLockedCounter()
            let handler = UsbControlHandler(
                manager: UsbipManager(),
                openDevice: { busID, _ in
                    opens.increment()
                    return UsbControlTestDevice(busID: busID)
                },
                notifyAttach: { _ in },
                notifyDetach: { _ in }
            )
            let server = UsbControlServer(path: path, handler: handler)
            try server.start()
            defer { _ = server.stop() }

            let response = try sendRawControlRequest(
                .attach(busID: try DoryUSBControlV1.BusID("3-2"), mode: .capture),
                path: path,
                timeout: 1
            )
            guard case .failure(let disposition, let message) = response else {
                Issue.record("policy-rejected mode did not return a shared failure")
                return
            }
            #expect(disposition == .rejected)
            #expect(message.contains("not authorized"))
            #expect(opens.value == 0)
        }
    }
}

@Suite(.serialized)
struct UsbipLifecycleHardeningTests {
    @Test func typedClaimLeaseRejectsCrossBusAndMismatchedAuthority() throws {
        let manager = UsbipManager(stopWaitLimit: 1)
        let crossBusDevice = UsbControlTestDevice(
            busID: "4-1",
            busNumber: 4,
            deviceNumber: 1
        )
        let attachLease = try manager.beginControlMutation(operation: .attach, busID: "3-2")
        #expect(
            throws: UsbipManagerError.controlMutationBusIDMismatch(
                expected: "3-2",
                actual: "4-1"
            )
        ) {
            try manager.register(crossBusDevice, under: attachLease)
        }
        #expect(crossBusDevice.shutdownCount == 1)
        manager.finishControlMutation(attachLease)

        let claimed = UsbControlTestDevice(busID: "3-2")
        try registerCommittedUSBClaim(claimed, with: manager)
        let mismatchedAttach = try manager.beginControlMutation(operation: .attach, busID: "3-2")
        #expect(throws: UsbipManagerError.claimLeaseMismatch("3-2")) {
            try manager.preserveClaimForReconciliation(under: mismatchedAttach)
        }
        manager.finishControlMutation(mismatchedAttach)

        let staleDetach = try manager.beginControlMutation(operation: .detach, busID: "3-2")
        manager.finishControlMutation(staleDetach)
        #expect(throws: UsbipManagerError.invalidControlMutationLease) {
            _ = try manager.unregisterClaim(under: staleDetach)
        }
        #expect(manager.claimedBusIDs == ["3-2"])
        _ = try unregisterUSBClaim(busID: "3-2", with: manager)
        #expect(claimed.shutdownCount == 1)
        #expect(manager.stop(timeout: 1))
    }

    @Test func managerBoundsClaimedDevicesAndReleasesRejectedClaim() throws {
        let manager = UsbipManager(maxClaimedDevices: 1, stopWaitLimit: 1)
        let first = UsbControlTestDevice(busID: "3-2")
        let rejected = UsbControlTestDevice(busID: "4-1", busNumber: 4, deviceNumber: 1)
        try registerCommittedUSBClaim(first, with: manager)
        #expect(throws: UsbipManagerError.deviceCapacityReached(limit: 1)) {
            try registerCommittedUSBClaim(rejected, with: manager)
        }
        #expect(rejected.shutdownCount == 1)
        #expect(manager.claimedBusIDs == ["3-2"])
        #expect(manager.stop(timeout: 1))
        #expect(first.shutdownCount == 1)
    }

    @Test func stopTimeoutDoesNotForgetAdmittedControlMutation() throws {
        let manager = UsbipManager(stopWaitLimit: 1)
        let mutation = try manager.beginControlMutation(operation: .attach, busID: "3-2")
        let started = ProcessInfo.processInfo.systemUptime
        #expect(!manager.stop(timeout: 0.02))
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.5)
        manager.finishControlMutation(mutation)
        #expect(manager.stop(timeout: 1))
    }

    @Test func guestTerminationExplicitlyRetiresAnUncertainClaimWithoutAnotherRPC() throws {
        let manager = UsbipManager(stopWaitLimit: 1)
        let device = UsbControlTestDevice(busID: "3-2")
        let mutation = try manager.beginControlMutation(operation: .attach, busID: "3-2")
        try manager.register(device, under: mutation)
        try manager.preserveClaimForReconciliation(under: mutation)
        manager.finishControlMutation(mutation)

        // A normal data-path stop cannot infer the guest outcome and must retain physical authority.
        #expect(!manager.stop(timeout: 1))
        #expect(manager.claimedBusIDs == ["3-2"])
        #expect(device.shutdownCount == 0)

        // The VM owner has now established that guest execution ended, which itself destroys vhci
        // state. No guest detach retry is needed or permitted beyond this boundary.
        #expect(manager.stopAfterGuestExecutionEnded(timeout: 1) == .completed)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(device.shutdownCount == 1)
        #expect(throws: UsbipManagerError.stopped) {
            try manager.beginControlMutation(operation: .detach, busID: "3-2")
        }
    }

    @Test func terminalBoundaryRetainsManagerUntilAnAdmittedMutationDrains() throws {
        var owner: UsbipManager? = UsbipManager(stopWaitLimit: 1)
        weak let retainedManager = owner
        let device = UsbControlTestDevice(busID: "3-2")
        let mutation: UsbipManagerControlMutationLease
        do {
            let manager = try #require(owner)
            mutation = try manager.beginControlMutation(operation: .attach, busID: "3-2")
            try manager.register(device, under: mutation)
        }

        let outcome = owner?.stopAfterGuestExecutionEnded(timeout: 0)
        #expect(outcome == .authorityRetained(retainedClaimBusIDs: ["3-2"]))
        #expect(device.shutdownCount == 0)

        // Simulate EngineMode/DesktopMode releasing their external owner after Machine.run ended.
        // The terminal worker, not the callsite, keeps exact host authority alive until the already
        // admitted mutation finishes.
        owner = nil
        #expect(retainedManager != nil)
        retainedManager?.finishControlMutation(mutation)
        #expect(waitUntil { device.shutdownCount == 1 })
        #expect(waitUntil { retainedManager == nil })
    }

    @Test func commitLinearizedBeforeStopRetiresClaimOnlyAfterMutationFinishes() async throws {
        let manager = UsbipManager(stopWaitLimit: 1)
        let device = UsbControlTestDevice(busID: "3-2")
        let mutation = try manager.beginControlMutation(operation: .attach, busID: "3-2")
        try manager.register(device, under: mutation)
        #expect(manager.withCurrentControlMutation(mutation, { true }) == true)

        let stopping = Task.detached { manager.stop(timeout: 1) }
        #expect(waitUntil { manager.isStopped })
        #expect(device.shutdownCount == 0)
        #expect(manager.claimedBusIDs == ["3-2"])

        manager.finishControlMutation(mutation)
        #expect(await stopping.value)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(device.shutdownCount == 1)
    }

    @Test func ordinaryCleanStopRetiresCommittedClaimsExactlyOnce() throws {
        let manager = UsbipManager(stopWaitLimit: 1)
        let device = UsbControlTestDevice(busID: "3-2")
        try registerCommittedUSBClaim(device, with: manager)

        #expect(manager.stop(timeout: 1))
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(device.shutdownCount == 1)
        #expect(manager.stop(timeout: 1))
        #expect(device.shutdownCount == 1)
    }

    @Test func managerAttachIsOneShotAndStopUnregistersAndDrainsBridge() throws {
        let vsock = VirtioVsock(guestCID: 3)
        let manager = UsbipManager(maxActiveConnections: 1, stopWaitLimit: 1)
        try registerCommittedUSBClaim(UsbControlTestDevice(busID: "3-2"), with: manager)
        try manager.attachListener(to: vsock)
        #expect(vsock.resourceSnapshot.listeners == 1)
        #expect(throws: UsbipManagerError.listenerAlreadyAttached) {
            try manager.attachListener(to: vsock)
        }

        _ = try vsock.receive(packet: guestVsockRequest(sourcePort: 40_000))
        #expect(waitUntil { manager.activeConnectionCount == 1 })
        _ = try vsock.receive(packet: guestVsockRequest(sourcePort: 40_001))
        #expect(waitUntil { manager.rejectedConnectionCount == 1 })

        #expect(manager.stop(timeout: 1))
        #expect(manager.activeConnectionCount == 0)
        #expect(vsock.resourceSnapshot.listeners == 0)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(throws: UsbipManagerError.stopped) {
            try manager.attachListener(to: vsock)
        }
    }

    @Test func managerCannotReplaceAnotherServiceListener() throws {
        let vsock = VirtioVsock(guestCID: 3)
        let first = UsbipManager()
        let second = UsbipManager()
        try first.attachListener(to: vsock)
        #expect(throws: VirtioVsockListenerRegistrationError.duplicatePort(VsockPorts.usbip)) {
            try second.attachListener(to: vsock)
        }
        #expect(first.stop(timeout: 1))
        try second.attachListener(to: vsock)
        #expect(second.stop(timeout: 1))
    }

    @Test func bridgeStopBeforeStartCompletesExactlyOnce() {
        let connection = UsbIdleVsockConnection()
        let completions = UsbLockedCounter()
        let bridge = UsbipBridge(
            connection: connection,
            server: UsbipServer(devices: []),
            authorizeImport: { _ in false },
            onClose: { completions.increment() }
        )
        bridge.requestStop()
        bridge.requestStop()
        bridge.start()
        bridge.serve()
        #expect(completions.value == 1)
        #expect(connection.closeCount == 1)
    }

    @Test func bridgeImportHandshakeHasWholeFrameDeadline() {
        let connection = UsbIdleVsockConnection()
        let completions = UsbLockedCounter()
        let bridge = UsbipBridge(
            connection: connection,
            server: UsbipServer(devices: []),
            handshakeTimeout: 0.02,
            authorizeImport: { _ in false },
            onClose: { completions.increment() }
        )
        let started = ProcessInfo.processInfo.systemUptime
        bridge.serve()
        #expect(ProcessInfo.processInfo.systemUptime - started < 1)
        #expect(completions.value == 1)
        #expect(connection.closeCount == 1)
    }

    @Test func bridgeImportHandshakeDeadlineIncludesPositiveTrickleProgress() {
        let connection = UsbTricklingVsockConnection()
        let completions = UsbLockedCounter()
        let bridge = UsbipBridge(
            connection: connection,
            server: UsbipServer(devices: []),
            handshakeTimeout: 0.01,
            authorizeImport: { _ in false },
            log: { _ in },
            onClose: { completions.increment() }
        )
        let started = ProcessInfo.processInfo.systemUptime
        bridge.serve()
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.2)
        #expect(completions.value == 1)
        #expect(connection.closeCount == 1)
    }

    @Test func bridgeRefusesImportWhenLiveAuthorizationExpired() throws {
        let device = UsbControlTestDevice(busID: "3-2")
        let connection = UsbBufferedVsockConnection()
        connection.feed(UsbipImportRequest(busID: "3-2").encoded())
        connection.finishAfterDrain()
        let bridge = UsbipBridge(
            connection: connection,
            server: UsbipServer(devices: [device]),
            authorizeImport: { _ in false },
            log: { _ in }
        )

        bridge.serve()

        #expect(connection.writes.count == UsbipOperationHeader.byteCount)
        #expect(try UsbipOperationHeader(decoding: connection.writes).status == 1)
    }

    @Test func unregisterTerminatesAdmittedPreImportGeneration() throws {
        let guestPort: UInt32 = 40_010
        let vsock = VirtioVsock(guestCID: 3)
        let manager = UsbipManager(stopWaitLimit: 1)
        try registerCommittedUSBClaim(UsbControlTestDevice(busID: "3-2"), with: manager)
        try manager.attachListener(to: vsock)
        _ = try vsock.receive(packet: guestVsockRequest(sourcePort: guestPort))
        #expect(waitUntil { manager.activeConnectionCount == 1 })

        _ = try unregisterUSBClaim(busID: "3-2", with: manager)
        #expect(manager.activeConnectionCount == 0)
        let importRequest = UsbipImportRequest(busID: "3-2").encoded()
        let immediate = try vsock.receive(
            packet: guestVsockReadWrite(sourcePort: guestPort, payload: importRequest)
        )
        let packets = immediate + vsock.drainPendingGuestPackets()
        let operations = try packets.map { try VirtioVsockHeader(decoding: $0).operation }
        #expect(!operations.contains(.readWrite))
        #expect(manager.stop(timeout: 1))
    }

    @Test func oneDeviceGenerationHasExactlyOneImportedBridgeOwner() throws {
        let firstPort: UInt32 = 40_020
        let secondPort: UInt32 = 40_021
        let vsock = VirtioVsock(guestCID: 3)
        let manager = UsbipManager(maxActiveConnections: 2, stopWaitLimit: 1)
        try registerCommittedUSBClaim(UsbControlTestDevice(busID: "3-2"), with: manager)
        try manager.attachListener(to: vsock)

        _ = try vsock.receive(packet: guestVsockRequest(sourcePort: firstPort))
        _ = try vsock.receive(
            packet: guestVsockReadWrite(
                sourcePort: firstPort,
                payload: UsbipImportRequest(busID: "3-2").encoded()
            )
        )
        let firstReply = try #require(waitForGuestReadWritePacket(vsock, destinationPort: firstPort))
        let firstPayload = Array(firstReply.dropFirst(VirtioVsockHeader.byteCount))
        #expect(try UsbipOperationHeader(decoding: firstPayload).status == 0)

        _ = try vsock.receive(packet: guestVsockRequest(sourcePort: secondPort))
        _ = try vsock.receive(
            packet: guestVsockReadWrite(
                sourcePort: secondPort,
                payload: UsbipImportRequest(busID: "3-2").encoded()
            )
        )
        let secondReply = try #require(waitForGuestReadWritePacket(vsock, destinationPort: secondPort))
        let secondPayload = Array(secondReply.dropFirst(VirtioVsockHeader.byteCount))
        #expect(secondPayload.count == UsbipOperationHeader.byteCount)
        #expect(try UsbipOperationHeader(decoding: secondPayload).status == 1)
        #expect(waitUntil { manager.activeConnectionCount == 1 })

        _ = try unregisterUSBClaim(busID: "3-2", with: manager)
        #expect(manager.activeConnectionCount == 0)
        #expect(manager.stop(timeout: 1))
    }
}

@Suite(.serialized)
struct UsbControlTransitionHardeningTests {
    @Test func canonicalBusIDValidationRunsBeforeCapabilityOrHardwareWork() async {
        #expect(DoryUSBControlV1.BusID.isValid("3-2.1:usb_A"))
        #expect(!DoryUSBControlV1.BusID.isValid(""))
        #expect(!DoryUSBControlV1.BusID.isValid("3/2"))
        #expect(!DoryUSBControlV1.BusID.isValid(String(repeating: "a", count: 32)))

        let supportChecks = UsbLockedCounter()
        let opens = UsbLockedCounter()
        let handler = UsbControlHandler(
            manager: UsbipManager(),
            ensureSupported: { supportChecks.increment() },
            openDevice: { busID, _ in
                opens.increment()
                return UsbControlTestDevice(busID: busID)
            },
            notifyAttach: { _ in },
            notifyDetach: { _ in }
        )
        await #expect(throws: UsbControlError.invalidBusID("3/2")) {
            _ = try await handler.attach(busID: "3/2")
        }
        await #expect(throws: UsbControlError.invalidBusID("3/2")) {
            try await handler.detach(busID: "3/2")
        }
        #expect(supportChecks.value == 0)
        #expect(opens.value == 0)
    }

    @Test func invalidDescriptorIdentityIsReleasedBeforeRegisterOrNotify() async {
        let device = UsbControlTestDevice(
            busID: "3-2",
            busNumber: UInt32(UInt16.max) + 1,
            deviceNumber: 2
        )
        let notifications = UsbLockedCounter()
        let manager = UsbipManager()
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { _, _ in device },
            notifyAttach: { _ in notifications.increment() },
            notifyDetach: { _ in }
        )

        await #expect(throws: UsbControlError.invalidDeviceIdentity(
            busID: "3-2",
            busNumber: UInt32(UInt16.max) + 1,
            deviceNumber: 2
        )) {
            _ = try await handler.attach(busID: "3-2")
        }
        #expect(device.shutdownCount == 1)
        #expect(notifications.value == 0)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
    }

    @Test func handlerPolicyRejectsPrivilegedModeBeforeCapabilityOrHardwareWork() async {
        let supportChecks = UsbLockedCounter()
        let opens = UsbLockedCounter()
        let manager = UsbipManager()
        let handler = UsbControlHandler(
            manager: manager,
            ensureSupported: { supportChecks.increment() },
            openDevice: { busID, _ in
                opens.increment()
                return UsbControlTestDevice(busID: busID)
            },
            notifyAttach: { _ in },
            notifyDetach: { _ in }
        )

        await #expect(throws: UsbControlError.openModeNotAllowed(.capture)) {
            _ = try await handler.attach(busID: "3-2", mode: .capture)
        }
        #expect(supportChecks.value == 0)
        #expect(opens.value == 0)
        #expect(manager.claimedBusIDs.isEmpty)
    }

    @Test func stopTracksCapabilityNegotiationAndPreventsLaterHardwareOpen() async throws {
        let gate = UsbAsyncGate()
        let opens = UsbLockedCounter()
        let manager = UsbipManager(stopWaitLimit: 1)
        let handler = UsbControlHandler(
            manager: manager,
            ensureSupported: { await gate.block() },
            openDevice: { busID, _ in
                opens.increment()
                return UsbControlTestDevice(busID: busID)
            },
            notifyAttach: { _ in },
            notifyDetach: { _ in }
        )
        let attaching = Task { try await handler.attach(busID: "3-2") }
        await gate.waitUntilBlocked()
        let stopping = Task.detached { manager.stop(timeout: 1) }
        #expect(waitUntil { manager.isStopped })
        await gate.release()

        do {
            _ = try await attaching.value
            Issue.record("attach continued into hardware after manager stop")
        } catch let error as UsbControlError {
            #expect(error == .managerStoppedDuringTransition("3-2"))
        }
        #expect(await stopping.value)
        #expect(opens.value == 0)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
    }

    @Test func detachDuringAttachGetsTypedTransitionAndAttachCommitsOnce() async throws {
        let gate = UsbAsyncGate()
        let manager = UsbipManager()
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
            notifyAttach: { _ in await gate.block() },
            notifyDetach: { _ in }
        )
        let attaching = Task { try await handler.attach(busID: "3-2") }
        await gate.waitUntilBlocked()
        do {
            try await handler.detach(busID: "3-2")
            Issue.record("detach unexpectedly crossed an attach transition")
        } catch let error as UsbControlError {
            #expect(error == .transitionInProgress(busID: "3-2", operation: "attaching"))
        }
        await gate.release()
        _ = try await attaching.value
        #expect(handler.attachedBusIDs == ["3-2"])
        #expect(manager.claimedBusIDs == ["3-2"])
    }

    @Test func attachRPCFailureWithSuccessfulCompensationIsRejectedAndReleasesClaim() async {
        let manager = UsbipManager()
        let detachCalls = UsbLockedCounter()
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
            notifyAttach: { _ in throw UsbTestRPCError("attach transport lost") },
            notifyDetach: { _ in detachCalls.increment() }
        )

        do {
            _ = try await handler.attach(busID: "3-2")
            Issue.record("attach unexpectedly succeeded after its RPC failed")
        } catch let error as UsbControlError {
            #expect(error.failureDisposition == .rejected)
            guard case .mutationRejected(let operation, let busID, _) = error else {
                Issue.record("compensated attach did not return a typed rejection")
                return
            }
            #expect(operation == .attach)
            #expect(busID == "3-2")
        } catch {
            Issue.record("unexpected compensated attach error: \(error)")
        }
        #expect(detachCalls.value == 1)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
        #expect(handler.uncertainBusIDs.isEmpty)
    }

    @Test func attachCompensationFailureIsWireUnknownAndLaterDetachReconciles() throws {
        try withTemporarySocketPath("attach-uncertain") { path in
            let manager = UsbipManager()
            let detachCalls = UsbLockedCounter()
            let handler = UsbControlHandler(
                manager: manager,
                openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
                notifyAttach: { _ in throw UsbTestRPCError("attach reply lost") },
                notifyDetach: { _ in
                    detachCalls.increment()
                    if detachCalls.value == 1 {
                        throw UsbTestRPCError("compensation reply lost")
                    }
                }
            )
            let server = UsbControlServer(path: path, handler: handler)
            try server.start()
            defer { _ = server.stop() }
            let busID = try DoryUSBControlV1.BusID("3-2")

            let attach = try sendRawControlRequest(
                .attach(busID: busID, mode: .userAuthorized),
                path: path,
                timeout: 2
            )
            guard case .failure(let disposition, _) = attach else {
                Issue.record("uncertain attach did not return a shared failure")
                return
            }
            #expect(disposition == .outcomeUnknown)
            #expect(manager.claimedBusIDs == ["3-2"])
            #expect(handler.uncertainBusIDs == ["3-2"])

            let detach = try sendRawControlRequest(
                .detach(busID: busID),
                path: path,
                timeout: 2
            )
            #expect(detach == .detachSuccess)
            #expect(detachCalls.value == 2)
            #expect(manager.claimedBusIDs.isEmpty)
            #expect(handler.attachedBusIDs.isEmpty)
            #expect(handler.uncertainBusIDs.isEmpty)
        }
    }

    @Test func failedDetachPreservesClaimAndReturnsTypedOutcomeUnknown() async throws {
        let manager = UsbipManager()
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
            notifyAttach: { _ in },
            notifyDetach: { request in throw UsbControlError.notAttached(request.busid) }
        )
        _ = try await handler.attach(busID: "3-2")
        do {
            try await handler.detach(busID: "3-2")
            Issue.record("failed detach unexpectedly succeeded")
        } catch let error as UsbControlError {
            #expect(error.failureDisposition == .outcomeUnknown)
            guard case .outcomeUnknown(let operation, let busID, _) = error else {
                Issue.record("failed detach was not explicitly classified as unknown")
                return
            }
            #expect(operation == .detach)
            #expect(busID == "3-2")
        }
        #expect(handler.attachedBusIDs == ["3-2"])
        #expect(handler.uncertainBusIDs.isEmpty)
        #expect(manager.claimedBusIDs == ["3-2"])
    }

    @Test func attachDuringDetachGetsTypedTransitionAndPortReleasesAfterCommit() async throws {
        let gate = UsbAsyncGate()
        let manager = UsbipManager()
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
            notifyAttach: { _ in },
            notifyDetach: { _ in await gate.block() }
        )
        _ = try await handler.attach(busID: "3-2")
        let detaching = Task { try await handler.detach(busID: "3-2") }
        await gate.waitUntilBlocked()
        do {
            _ = try await handler.attach(busID: "3-2")
            Issue.record("attach unexpectedly crossed a detach transition")
        } catch let error as UsbControlError {
            #expect(error == .transitionInProgress(busID: "3-2", operation: "detaching"))
        }
        await gate.release()
        try await detaching.value
        let attachedAgain = try await handler.attach(busID: "3-2")
        #expect(attachedAgain.port == 0)
    }

    @Test func stopDuringGuestAttachCompensatesAndCannotCommitStaleState() async throws {
        let gate = UsbAsyncGate()
        let detachCalls = UsbLockedCounter()
        let manager = UsbipManager(stopWaitLimit: 1)
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
            notifyAttach: { _ in await gate.block() },
            notifyDetach: { _ in detachCalls.increment() }
        )
        let attaching = Task { try await handler.attach(busID: "3-2") }
        await gate.waitUntilBlocked()
        #expect(manager.claimedBusIDs == ["3-2"])
        let stopping = Task.detached { manager.stop(timeout: 1) }
        #expect(waitUntil { manager.isStopped })
        await gate.release()

        do {
            _ = try await attaching.value
            Issue.record("attach committed after manager stop")
        } catch let error as UsbControlError {
            #expect(error.failureDisposition == .rejected)
            guard case .mutationRejected(let operation, let busID, let detail) = error else {
                Issue.record("compensated stale attach was not a typed rejection")
                return
            }
            #expect(operation == .attach)
            #expect(busID == "3-2")
            #expect(detail.contains("manager stopped"))
        }
        #expect(await stopping.value)
        #expect(detachCalls.value == 1)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
    }

    @Test func stopPreservesFailedAttachCompensationUntilLaterDetachReconciles() async throws {
        let attachGate = UsbAsyncGate()
        let detachCalls = UsbLockedCounter()
        let opens = UsbLockedCounter()
        let device = UsbControlTestDevice(busID: "3-2")
        let manager = UsbipManager(stopWaitLimit: 1)
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { _, _ in
                opens.increment()
                return device
            },
            notifyAttach: { _ in await attachGate.block() },
            notifyDetach: { _ in
                detachCalls.increment()
                if detachCalls.value == 1 {
                    throw UsbTestRPCError("detach compensation reply lost")
                }
            }
        )
        let attaching = Task { try await handler.attach(busID: "3-2") }
        await attachGate.waitUntilBlocked()
        #expect(manager.claimedBusIDs == ["3-2"])

        let stopping = Task.detached { manager.stop(timeout: 1) }
        #expect(waitUntil { manager.isStopped })
        await attachGate.release()
        do {
            _ = try await attaching.value
            Issue.record("attach committed after stop invalidated its generation")
        } catch let error as UsbControlError {
            guard case .outcomeUnknown(let operation, let busID, _) = error else {
                Issue.record("failed compensation was not outcome-unknown: \(error)")
                return
            }
            #expect(operation == .attach)
            #expect(busID == "3-2")
        }

        #expect(!(await stopping.value))
        #expect(manager.claimedBusIDs == ["3-2"])
        #expect(handler.uncertainBusIDs == ["3-2"])
        #expect(device.shutdownCount == 0)
        #expect(detachCalls.value == 1)

        do {
            _ = try await handler.attach(busID: "4-1")
            Issue.record("quiesced manager admitted a new attach")
        } catch let error as UsbipManagerError {
            #expect(error == .stopped)
        }
        #expect(opens.value == 1)

        try await handler.detach(busID: "3-2")
        #expect(detachCalls.value == 2)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
        #expect(device.shutdownCount == 1)
        #expect(manager.stop(timeout: 1))
    }

    @Test func failedDetachDuringTeardownIsExplicitlyOutcomeUnknown() async throws {
        let gate = UsbAsyncGate()
        let detachCalls = UsbLockedCounter()
        let manager = UsbipManager(stopWaitLimit: 1)
        let handler = UsbControlHandler(
            manager: manager,
            openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
            notifyAttach: { _ in },
            notifyDetach: { request in
                detachCalls.increment()
                if detachCalls.value == 1 {
                    await gate.block()
                    throw UsbControlError.notAttached(request.busid)
                }
            }
        )
        _ = try await handler.attach(busID: "3-2")
        let detaching = Task { try await handler.detach(busID: "3-2") }
        await gate.waitUntilBlocked()
        let stopping = Task.detached { manager.stop(timeout: 1) }
        #expect(waitUntil { manager.isStopped })
        await gate.release()

        do {
            try await detaching.value
            Issue.record("failed guest detach unexpectedly succeeded")
        } catch let error as UsbControlError {
            switch error {
            case .outcomeUnknown(let operation, let busID, let detail):
                #expect(operation == .detach)
                #expect(busID == "3-2")
                #expect(detail.contains("guest detach RPC failed"))
            default:
                Issue.record("unexpected detach error: \(error)")
            }
        }
        #expect(!(await stopping.value))
        #expect(manager.claimedBusIDs == ["3-2"])
        #expect(handler.attachedBusIDs == ["3-2"])
        try await handler.detach(busID: "3-2")
        #expect(detachCalls.value == 2)
        #expect(manager.claimedBusIDs.isEmpty)
        #expect(handler.attachedBusIDs.isEmpty)
        #expect(manager.stop(timeout: 1))
    }
}

private actor UsbAsyncGate {
    private var blocked = false
    private var released = false
    private var blockContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuations: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        let observers = observerContinuations
        observerContinuations.removeAll()
        for observer in observers { observer.resume() }
        if released { return }
        await withCheckedContinuation { blockContinuation = $0 }
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { observerContinuations.append($0) }
    }

    func release() {
        released = true
        blockContinuation?.resume()
        blockContinuation = nil
    }
}

private final class UsbControlTestDevice: UsbipExportedDevice, @unchecked Sendable {
    let descriptor: UsbipDeviceDescriptor
    private let lock = NSLock()
    private var storedShutdownCount = 0

    init(busID: String, busNumber: UInt32 = 3, deviceNumber: UInt32 = 2) {
        descriptor = UsbipDeviceDescriptor(
            path: "/sys/devices/usb/\(busID)",
            busID: busID,
            busNumber: busNumber,
            deviceNumber: deviceNumber,
            speed: 2,
            vendorID: 1,
            productID: 2,
            bcdDevice: 0x100,
            deviceClass: 0xff,
            deviceSubClass: 0,
            deviceProtocol: 0,
            configurationValue: 1,
            configurationCount: 1,
            interfaceCount: 1
        )
    }

    func submit(
        _ command: UsbipSubmitCommand,
        context: UsbipRequestContext
    ) throws -> UsbipSubmitReply {
        throw UsbipServerError.unknownDevice(descriptor.busID)
    }

    func unlink(
        _ command: UsbipUnlinkCommand,
        context: UsbipRequestContext
    ) throws -> UsbipUnlinkReply {
        throw UsbipServerError.unknownDevice(descriptor.busID)
    }

    var shutdownCount: Int { lock.withLock { storedShutdownCount } }
    func closeSession(_ context: UsbipRequestContext) {}
    func shutdown() { lock.withLock { storedShutdownCount += 1 } }
}

private final class UsbIdleVsockConnection: VsockConnection, @unchecked Sendable {
    private let condition = NSCondition()
    private var closed = false
    private var storedCloseCount = 0

    var closeCount: Int {
        condition.lock(); defer { condition.unlock() }
        return storedCloseCount
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int { 0 }
    func write(_ bytes: [UInt8]) throws {}
    func shutdownSend() {}

    func close() {
        condition.lock()
        if !closed {
            closed = true
            storedCloseCount += 1
        }
        condition.broadcast()
        condition.unlock()
    }

    func waitForReadable(timeoutNanoseconds: UInt64?) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if closed { return true }
        if let timeoutNanoseconds {
            _ = condition.wait(
                until: Date().addingTimeInterval(Double(timeoutNanoseconds) / 1_000_000_000)
            )
        } else {
            condition.wait()
        }
        return closed
    }

    var isPeerClosed: Bool {
        condition.lock(); defer { condition.unlock() }
        return closed
    }
}

private final class UsbTricklingVsockConnection: VsockConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var storedCloseCount = 0

    var closeCount: Int { lock.withLock { storedCloseCount } }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        usleep(30_000)
        guard buffer.count > 0 else { return 0 }
        buffer[0] = 0
        return 1
    }

    func write(_ bytes: [UInt8]) throws {}
    func shutdownSend() {}
    func close() {
        lock.withLock {
            if !closed {
                closed = true
                storedCloseCount += 1
            }
        }
    }
    var isPeerClosed: Bool { lock.withLock { closed } }
}

private final class UsbBufferedVsockConnection: VsockConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [UInt8] = []
    private var outbound: [UInt8] = []
    private var peerFinished = false
    private var closed = false

    var writes: [UInt8] { lock.withLock { outbound } }
    func feed(_ bytes: [UInt8]) { lock.withLock { inbound.append(contentsOf: bytes) } }
    func finishAfterDrain() { lock.withLock { peerFinished = true } }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        lock.withLock {
            let count = min(buffer.count, inbound.count)
            guard count > 0 else { return 0 }
            inbound.prefix(count).withUnsafeBytes { source in
                buffer.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: count)
            }
            inbound.removeFirst(count)
            return count
        }
    }

    func write(_ bytes: [UInt8]) throws { lock.withLock { outbound.append(contentsOf: bytes) } }
    func shutdownSend() {}
    func close() { lock.withLock { closed = true } }
    var isPeerClosed: Bool { lock.withLock { closed || (peerFinished && inbound.isEmpty) } }
}

private final class UsbLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func increment() { lock.withLock { stored += 1 } }
}

private final class UsbLockedDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?
    var value: Int32? { lock.withLock { stored } }
    func store(_ descriptor: Int32) { lock.withLock { stored = descriptor } }
}

private final class UsbLockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private final class UsbInjectedReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func read(
        _ descriptor: Int32,
        _ destination: UnsafeMutableRawPointer?,
        _ requested: Int
    ) -> Int {
        let count = min(requested, bytes.count - offset)
        guard count > 0 else { return 0 }
        bytes.withUnsafeBytes { source in
            destination?.copyMemory(
                from: source.baseAddress!.advanced(by: offset),
                byteCount: count
            )
        }
        offset += count
        return count
    }
}

private func guestVsockRequest(sourcePort: UInt32) -> [UInt8] {
    VirtioVsockHeader(
        sourceCID: 3,
        destinationCID: 2,
        sourcePort: sourcePort,
        destinationPort: VsockPorts.usbip,
        length: 0,
        operation: .request
    ).encoded()
}

private func guestVsockReadWrite(sourcePort: UInt32, payload: [UInt8]) -> [UInt8] {
    VirtioVsockHeader(
        sourceCID: 3,
        destinationCID: 2,
        sourcePort: sourcePort,
        destinationPort: VsockPorts.usbip,
        length: UInt32(payload.count),
        operation: .readWrite
    ).encoded() + payload
}

private func makeControlHandler() -> UsbControlHandler {
    UsbControlHandler(
        manager: UsbipManager(),
        openDevice: { busID, _ in UsbControlTestDevice(busID: busID) },
        notifyAttach: { _ in },
        notifyDetach: { _ in }
    )
}

private func withTemporarySocketPath(
    _ label: String,
    body: (String) throws -> Void
) throws {
    let root = "/tmp/dory-usb-\(label)-\(getpid())-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    guard chmod(root, 0o700) == 0 else {
        throw UsbControlServerError.systemCall(
            operation: "secure temporary USB control directory",
            code: errno
        )
    }
    defer { try? FileManager.default.removeItem(atPath: root) }
    try body(root + "/control.sock")
}

private func writeRaw(_ descriptor: Int32, _ data: Data) throws {
    try UsbControlSocketIO.writeAll(
        descriptor: descriptor,
        bytes: data,
        deadline: ProcessInfo.processInfo.systemUptime + 1
    )
}

private func sendRawControlRequest(
    _ request: DoryUSBControlV1.Request,
    path: String,
    timeout: TimeInterval
) throws -> DoryUSBControlV1.Response {
    var frame = try DoryUSBControlV1.encodeRequest(request)
    frame.append(0x0a)
    return try sendRawControlFrame(frame, path: path, timeout: timeout)
}

private func sendRawControlFrame(
    _ frame: Data,
    path: String,
    timeout: TimeInterval
) throws -> DoryUSBControlV1.Response {
    let descriptor = try connectRawUnixSocket(path)
    defer { close(descriptor) }
    guard UsbControlSocketIO.configureOwnedSocket(descriptor, nonBlocking: true) else {
        throw UsbControlServerError.systemCall(
            operation: "configure raw test control socket",
            code: errno
        )
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    try UsbControlSocketIO.writeAll(
        descriptor: descriptor,
        bytes: frame,
        deadline: deadline
    )
    let response = try UsbControlSocketIO.readFrame(
        descriptor: descriptor,
        deadline: deadline
    )
    return try DoryUSBControlV1.decodeResponse(response)
}

private func framedRawJSON(_ json: String) -> Data {
    var data = Data(json.utf8)
    data.append(0x0a)
    return data
}

private struct UsbHostileControlError: Error, CustomStringConvertible {
    let description = String(repeating: "\n😀\\\"", count: 4_000)
}

private struct UsbTestRPCError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private func connectRawUnixSocket(_ path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw UsbControlServerError.systemCall(operation: "create test client", code: errno)
    }
    guard UsbControlSocketIO.configureOwnedSocket(descriptor, nonBlocking: false) else {
        let code = errno
        close(descriptor)
        throw UsbControlServerError.systemCall(operation: "configure test client", code: code)
    }
    var address = try UsbControlSocketIO.address(for: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        close(descriptor)
        throw UsbControlServerError.systemCall(operation: "connect test client", code: code)
    }
    return descriptor
}

private func makeRawUnixListener(_ path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw UsbControlServerError.systemCall(operation: "create replacement listener", code: errno)
    }
    var address = try UsbControlSocketIO.address(for: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0, listen(descriptor, 1) == 0 else {
        let code = errno
        close(descriptor)
        throw UsbControlServerError.systemCall(operation: "bind replacement listener", code: code)
    }
    return descriptor
}

private func waitUntil(
    timeout: TimeInterval = 2,
    predicate: () -> Bool
) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if predicate() { return true }
        usleep(1_000)
    }
    return predicate()
}

private func waitForGuestReadWritePacket(
    _ vsock: VirtioVsock,
    destinationPort: UInt32,
    timeout: TimeInterval = 2
) -> [UInt8]? {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        for packet in vsock.drainPendingGuestPackets() {
            guard let header = try? VirtioVsockHeader(decoding: packet) else { continue }
            if header.operation == .readWrite, header.destinationPort == destinationPort {
                return packet
            }
        }
        usleep(1_000)
    }
    return nil
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock(); defer { unlock() }
        return try body()
    }
}
