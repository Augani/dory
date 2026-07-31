import CoreServices
import Foundation
import Testing
@testable import DoryHV

struct VirtioFSTests {
    @Test func exposesVirtioFSDeviceIdentityAndQueues() throws {
        let root = try TestVirtioFSRoot()
        let fs = try VirtioFS(tag: "home", hostFS: HostFS(rootPath: root.url.path), requestQueueCount: 4)

        #expect(fs.deviceID == 26)
        #expect(fs.requestQueueCount == 4)
        #expect(fs.queueCount == 6)
        #expect(fs.deviceFeatures & VirtioFS.notificationFeature != 0)
        #expect(fs.kickSynchronization == .backendManaged)
    }

    @Test func configSpaceContainsPaddedTagAndConfiguredRequestQueues() throws {
        let root = try TestVirtioFSRoot()
        let fs = try VirtioFS(tag: "home", hostFS: HostFS(rootPath: root.url.path), requestQueueCount: 4)
        let config = fs.configSpace

        #expect(config.count == 44)
        #expect(String(decoding: config[0..<4], as: UTF8.self) == "home")
        #expect(config[4..<VirtioFS.tagByteCount].allSatisfy { $0 == 0 })
        #expect(config[36..<40].elementsEqual([4, 0, 0, 0]))
        #expect(config[40..<44].elementsEqual([0, 16, 0, 0]))
    }

    @Test func notificationEncodersMatchFuseWireLayout() throws {
        let inode = try VirtioFSInvalidation.inode(
            nodeID: 0x0102_0304_0506_0708,
            offset: -2,
            length: 0x1112_1314_1516_1718
        ).encoded()
        #expect(inode.count == 40)
        #expect(inode.leUInt32(at: 0) == 40)
        #expect(inode.leUInt32(at: 4) == VirtioFSInvalidation.invalidateInodeCode)
        #expect(inode.leUInt64(at: 8) == 0)
        #expect(inode.leUInt64(at: 16) == 0x0102_0304_0506_0708)
        #expect(inode.leUInt64(at: 24) == UInt64(bitPattern: -2))
        #expect(inode.leUInt64(at: 32) == 0x1112_1314_1516_1718)

        let entry = try VirtioFSInvalidation.entry(
            parentNodeID: 0x2122_2324_2526_2728,
            name: "node.js",
            flags: 0x3132_3334
        ).encoded()
        #expect(entry.count == 40)
        #expect(entry.leUInt32(at: 0) == 40)
        #expect(entry.leUInt32(at: 4) == VirtioFSInvalidation.invalidateEntryCode)
        #expect(entry.leUInt64(at: 8) == 0)
        #expect(entry.leUInt64(at: 16) == 0x2122_2324_2526_2728)
        #expect(entry.leUInt32(at: 24) == 7)
        #expect(entry.leUInt32(at: 28) == 0x3132_3334)
        #expect(Array(entry[32..<39]) == Array("node.js".utf8))
        #expect(entry[39] == 0)

        let delete = try VirtioFSInvalidation.delete(
            parentNodeID: 0x4142_4344_4546_4748,
            childNodeID: 0x5152_5354_5556_5758,
            name: "node.js"
        ).encoded()
        #expect(delete.count == 48)
        #expect(delete.leUInt32(at: 0) == 48)
        #expect(delete.leUInt32(at: 4) == VirtioFSInvalidation.deleteCode)
        #expect(delete.leUInt64(at: 8) == 0)
        #expect(delete.leUInt64(at: 16) == 0x4142_4344_4546_4748)
        #expect(delete.leUInt64(at: 24) == 0x5152_5354_5556_5758)
        #expect(delete.leUInt32(at: 32) == 7)
        #expect(delete.leUInt32(at: 36) == 0)
        #expect(Array(delete[40..<47]) == Array("node.js".utf8))
        #expect(delete[47] == 0)

        for name in ["", ".", "..", "a/b", "a\0b", String(repeating: "x", count: 256)] {
            #expect(throws: VirtioFSNotificationError.invalidEntryName(name)) {
                _ = try VirtioFSInvalidation.entry(parentNodeID: 1, name: name).encoded()
            }
            #expect(throws: VirtioFSNotificationError.invalidEntryName(name)) {
                _ = try VirtioFSInvalidation.delete(parentNodeID: 1, childNodeID: 2, name: name).encoded()
            }
        }
    }

    @Test func legacyGuestKeepsQueueOneAsARequestQueue() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        try harness.configureQueue(2)
        try harness.postWritableBuffer(queue: 1, descriptor: 0, address: harness.bufferAddress(0), slot: 0, index: 1)
        try harness.postWritableBuffer(queue: 2, descriptor: 0, address: harness.bufferAddress(1), slot: 0, index: 1)
        harness.setDriverReady(notifications: false)

        harness.fs.handleKick(queue: 1, transport: harness.transport)
        harness.fs.handleKick(queue: 2, transport: harness.transport)

        #expect(try harness.usedIndex(queue: 1) == 1)
        #expect(try harness.usedIndex(queue: 2) == 0)
        do {
            _ = try await harness.fs.submitInvalidation(.inode(nodeID: 1))
            Issue.record("legacy transport unexpectedly admitted an invalidation")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .featureNotNegotiated)
        }
    }

    @Test func highLevelInvalidationFailureLatchesRequestPublicationUntilBackendReplacement() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)

        do {
            try await harness.fs.invalidate([.inode(nodeID: 1)], timeout: .milliseconds(20))
            Issue.record("legacy transport unexpectedly completed a high-level invalidation")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .featureNotNegotiated)
        }

        #expect(harness.fs.requestPublicationGateClosed)
        let blocked = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 401),
            queue: 1
        )
        #expect(await eventually { harness.fs.deferredRequestQueueSnapshot.contains(1) })
        #expect(try harness.responseLength(blocked) == 0)

        // A guest-controlled device reset and queue reconstruction cannot prove that stale dirty
        // page cache was discarded. Only constructing the replacement backend may clear the latch.
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let afterReset = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 402),
            queue: 1
        )
        #expect(harness.fs.requestPublicationGateClosed)
        #expect(try harness.responseLength(afterReset) == 0)
    }

    @Test func highLevelInvalidationSuccessReleasesRetainedGateAndRedrainsRequests() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.prepareCoherentCachingEligibility()

        let fs = harness.fs
        let invalidation = Task {
            try await fs.invalidate([.inode(nodeID: 1)], timeout: .seconds(1))
        }
        #expect(await eventually { fs.requestPublicationGateClosed })
        #expect(await eventually { (try? harness.usedIndex(queue: 1)) == 1 })

        let deferred = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 409),
            queue: 2
        )
        #expect(await eventually { fs.deferredRequestQueueSnapshot.contains(2) })
        #expect(try harness.responseLength(deferred) == 0)

        try harness.acknowledgeFirstInvalidation()
        try await invalidation.value

        #expect(!fs.requestPublicationGateClosed)
        #expect(try FuseProtocol.decodeOutHeader(harness.waitForFuseResponse(deferred)).unique == 409)
    }

    @Test func failedLowLevelSubmissionRedrainsDeferredLegacyQueueAcrossOwnershipHandoff() async throws {
        let harness = try VirtioFSNotificationHarness(requestQueueCount: 2, inlineRequests: false)
        try harness.configureQueue(1)
        try harness.configureQueue(2)
        harness.setDriverReady(notifications: false)

        let activeEncoded = DispatchSemaphore(value: 0)
        let releaseActive = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 410, opcode == .statfs else { return }
            activeEncoded.signal()
            releaseActive.wait()
        }

        let requestDeferred = DispatchSemaphore(value: 0)
        let scheduledKickCollided = DispatchSemaphore(value: 0)
        let releaseDeferredDrainer = DispatchSemaphore(value: 0)
        harness.fs.requestGateDrainTestHook = { event in
            switch event {
            case .deferred(queue: 2):
                requestDeferred.signal()
                releaseDeferredDrainer.wait()
            case .kickCollidedWithActiveDrainer(queue: 2):
                scheduledKickCollided.signal()
            default:
                break
            }
        }
        defer {
            releaseActive.signal()
            releaseDeferredDrainer.signal()
            harness.fs.responseFenceTestHook = nil
            harness.fs.requestGateDrainTestHook = nil
        }

        let active = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 410),
            queue: 1
        )
        #expect(await semaphoreSignals(activeEncoded))

        let fs = harness.fs
        let submission = Task {
            try await fs.submitInvalidation(.inode(nodeID: 1))
        }
        #expect(await eventually { fs.requestPublicationGateClosed })

        // Queue 2 reaches the closed gate and keeps its drainer ownership while the low-level
        // submission discovers that this legacy guest did not negotiate notifications.
        let deferred = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 411),
            queue: 2
        )
        #expect(await semaphoreSignals(requestDeferred))

        releaseActive.signal()
        do {
            _ = try await submission.value
            Issue.record("legacy transport unexpectedly admitted an invalidation")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .featureNotNegotiated)
        }
        #expect(!fs.requestPublicationGateClosed)

        // Gate reopening schedules the only redrain kick. Force it to collide with the old drainer,
        // then let that drainer observe the advanced generation and consume the posted descriptor.
        #expect(await semaphoreSignals(scheduledKickCollided))
        releaseDeferredDrainer.signal()

        #expect(try FuseProtocol.decodeOutHeader(harness.waitForFuseResponse(active)).unique == 410)
        #expect(try FuseProtocol.decodeOutHeader(harness.waitForFuseResponse(deferred)).unique == 411)
    }

    @Test func negotiatedGuestRetainsQueueOneAndStartsRequestsAtQueueTwo() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        try harness.configureQueue(2)
        try harness.postWritableBuffer(queue: 1, descriptor: 0, address: harness.bufferAddress(0), slot: 0, index: 1)
        try harness.postWritableBuffer(queue: 2, descriptor: 0, address: harness.bufferAddress(1), slot: 0, index: 1)
        harness.setDriverReady(notifications: true)

        harness.fs.handleKick(queue: 1, transport: harness.transport)
        harness.fs.handleKick(queue: 2, transport: harness.transport)

        #expect(try harness.usedIndex(queue: 1) == 0)
        #expect(try harness.usedIndex(queue: 2) == 1)
    }

    @Test func managedTransportKicksRunIndependentRequestQueuesConcurrently() throws {
        let harness = try VirtioFSNotificationHarness(requestQueueCount: 2, inlineRequests: true)
        try harness.configureQueue(2)
        try harness.configureQueue(3)
        harness.setDriverReady(notifications: true)

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard (header.unique == 201 || header.unique == 202), opcode == .statfs else { return }
            entered.signal()
            release.wait()
        }
        let first = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 201),
            queue: 2,
            kick: false
        )
        let second = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 202),
            queue: 3,
            kick: false
        )

        let group = DispatchGroup()
        let transport = harness.transport
        for queue in [2, 3] {
            group.enter()
            DispatchQueue.global().async {
                transport.write(offset: 0x050, value: UInt64(queue), width: 4)
                group.leave()
            }
        }
        guard entered.wait(timeout: .now() + 2) == .success,
              entered.wait(timeout: .now() + 2) == .success else {
            release.signal()
            release.signal()
            _ = group.wait(timeout: .now() + 2)
            Issue.record("independent virtio-fs queue kicks remained globally serialized")
            return
        }

        release.signal()
        release.signal()
        #expect(group.wait(timeout: .now() + 2) == .success)
        #expect(try FuseProtocol.decodeOutHeader(harness.waitForFuseResponse(first)).unique == 201)
        #expect(try FuseProtocol.decodeOutHeader(harness.waitForFuseResponse(second)).unique == 202)
    }

    @Test func resetAndQueueReconfigureRejectResponseFromOldRequestEpoch() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)

        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 301, opcode == .statfs else { return }
            encoded.signal()
            release.wait()
        }
        _ = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 301),
            queue: 1
        )
        #expect(await semaphoreSignals(encoded))

        // Reset invalidates the popped request's epoch. Rebuilding QueueReady must allow a fresh
        // drainer immediately, while the old response is discarded when its host work resumes.
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        release.signal()

        let fresh = try harness.performFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 302),
            queue: 1
        )
        #expect(try FuseProtocol.decodeOutHeader(fresh).unique == 302)
        #expect(try harness.usedIndex(queue: 1) == 1)
    }

    @Test func queueEpochDropRollsBackAnUnpublishedLookupReference() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("payload", to: "dropped.txt")
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 303, opcode == .lookup else { return }
            encoded.signal()
            release.wait()
        }
        defer {
            release.signal()
            harness.fs.responseFenceTestHook = nil
        }

        let pending = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 303, payload: Array("dropped.txt\0".utf8)),
            queue: 1
        )
        #expect(await semaphoreSignals(encoded))
        let encodedLookup = try harness.encodedResponse(pending)
        let droppedNodeID = Array(encodedLookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)

        harness.setQueueReady(1, false)
        release.signal()
        #expect(await eventually {
            do {
                _ = try harness.hostFS.cachedAttributes(nodeID: droppedNodeID)
                return false
            } catch HostFSError.notFound {
                return true
            } catch {
                return false
            }
        })

        try harness.configureQueue(1)
        let fresh = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 304, payload: Array("dropped.txt\0".utf8)),
            queue: 1
        )
        let freshNodeID = Array(fresh.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        #expect(freshNodeID > droppedNodeID)
    }

    @Test func undersizedResponseRollsBackLookupGrantAndPublishesCompleteEIOHeader() throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("payload", to: "undersized.txt")
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)

        let response = try harness.performFuseRequest(
            makeFuseRequest(
                opcode: .lookup,
                unique: 309,
                payload: Array("undersized.txt\0".utf8)
            ),
            queue: 1,
            responseCapacity: FuseOutHeader.byteCount
        )

        #expect(response.count == FuseOutHeader.byteCount)
        #expect(try FuseProtocol.decodeOutHeader(response).error == -FuseProtocol.linuxErrno(EIO))
        let snapshot = try #require(harness.hostFS.invalidationSnapshot(
            forHostPath: harness.rootURL.appendingPathComponent("undersized.txt").path
        ))
        #expect(snapshot.nodeIDs.isEmpty)
    }

    @Test func deviceResetWaitsForDroppedOpenThenRetiresOldHandlesAndNodes() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("payload", to: "reset-open.txt")
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let lookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 305, payload: Array("reset-open.txt\0".utf8)),
            queue: 1
        )
        let oldNodeID = Array(lookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 306, opcode == .open else { return }
            encoded.signal()
            release.wait()
        }
        defer {
            release.signal()
            harness.fs.responseFenceTestHook = nil
        }

        let pendingOpen = try harness.enqueueFuseRequest(
            makeFuseRequest(
                opcode: .open,
                unique: 306,
                nodeID: oldNodeID,
                payload: [UInt8](repeating: 0, count: 8)
            ),
            queue: 1
        )
        #expect(await semaphoreSignals(encoded))
        let encodedOpen = try harness.encodedResponse(pendingOpen)
        let staleHandle = Array(encodedOpen.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)

        harness.transport.write(offset: 0x070, value: 0, width: 4)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        release.signal()

        let staleRead = try harness.performFuseRequest(
            makeFuseReadRequest(
                unique: 307,
                nodeID: oldNodeID,
                handle: staleHandle,
                count: 16
            ),
            queue: 1
        )
        #expect(try FuseProtocol.decodeOutHeader(staleRead).error == -EBADF)
        #expect(throws: HostFSError.notFound("node \(oldNodeID)")) {
            _ = try harness.hostFS.cachedAttributes(nodeID: oldNodeID)
        }

        let fresh = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 308, payload: Array("reset-open.txt\0".utf8)),
            queue: 1
        )
        #expect(Array(fresh.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0) > oldNodeID)
    }

    @Test func notificationBarrierCompletesOnlyAfterSameBufferIsReposted() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        let address = harness.bufferAddress(0)
        try harness.postWritableBuffer(queue: 1, descriptor: 0, address: address, slot: 0, index: 1)
        harness.setDriverReady(notifications: true)
        harness.fs.handleKick(queue: 1, transport: harness.transport)

        let barrier = try await harness.fs.submitInvalidation(.inode(nodeID: 42, offset: -1, length: 0))

        #expect(try harness.usedIndex(queue: 1) == 1)
        #expect(!barrier.isCompleted)
        let frame = try harness.memory.readBytes(at: address, count: 40)
        #expect(frame.leUInt32(at: 0) == 40)
        #expect(frame.leUInt32(at: 4) == VirtioFSInvalidation.invalidateInodeCode)
        #expect(frame.leUInt64(at: 16) == 42)

        // virtio may choose a different descriptor head when Linux reposts the same node.buf.
        try harness.postWritableBuffer(queue: 1, descriptor: 3, address: address, slot: 1, index: 2)
        harness.fs.handleKick(queue: 1, transport: harness.transport)

        #expect(barrier.isCompleted)
        try await barrier.wait()
    }

    @Test func barriersPreserveSubmissionOrderAcrossOutOfOrderBufferReturns() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        let firstAddress = harness.bufferAddress(0)
        let secondAddress = harness.bufferAddress(1)
        try harness.postWritableBuffer(queue: 1, descriptor: 0, address: firstAddress, slot: 0, index: 1)
        try harness.postWritableBuffer(queue: 1, descriptor: 1, address: secondAddress, slot: 1, index: 2)
        harness.setDriverReady(notifications: true)
        harness.fs.handleKick(queue: 1, transport: harness.transport)

        // Buffers are consumed from the retained pool's tail: sequence 1 uses secondAddress.
        let first = try await harness.fs.submitInvalidation(.inode(nodeID: 1))
        let second = try await harness.fs.submitInvalidation(.inode(nodeID: 2))

        try harness.postWritableBuffer(queue: 1, descriptor: 2, address: firstAddress, slot: 2, index: 3)
        harness.fs.handleKick(queue: 1, transport: harness.transport)
        #expect(!first.isCompleted)
        #expect(!second.isCompleted)

        try harness.postWritableBuffer(queue: 1, descriptor: 3, address: secondAddress, slot: 3, index: 4)
        harness.fs.handleKick(queue: 1, transport: harness.transport)
        #expect(first.isCompleted)
        #expect(second.isCompleted)
        try await first.wait()
        try await second.wait()
    }

    @Test func pendingQueueAppliesAtomicBackpressure() async throws {
        let harness = try VirtioFSNotificationHarness(notificationBacklogLimit: 1)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: true)

        do {
            _ = try await harness.fs.submitInvalidations([.inode(nodeID: 1), .inode(nodeID: 2)])
            Issue.record("oversized invalidation batch unexpectedly admitted")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .backpressure(limit: 1))
        }
        let admitted = try await harness.fs.submitInvalidation(.inode(nodeID: 3))
        #expect(!admitted.isCompleted)
        do {
            _ = try await harness.fs.submitInvalidation(.inode(nodeID: 4))
            Issue.record("full invalidation backlog unexpectedly admitted another item")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .backpressure(limit: 1))
        }
    }

    @Test func deviceResetFailsAnInFlightBarrierSynchronously() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        try harness.postWritableBuffer(queue: 1, descriptor: 0, address: harness.bufferAddress(0), slot: 0, index: 1)
        harness.setDriverReady(notifications: true)
        harness.fs.handleKick(queue: 1, transport: harness.transport)
        let barrier = try await harness.fs.submitInvalidation(.inode(nodeID: 7))
        #expect(!barrier.isCompleted)

        harness.transport.write(offset: 0x070, value: 0, width: 4)

        #expect(barrier.isCompleted)
        do {
            try await barrier.wait()
            Issue.record("reset barrier unexpectedly succeeded")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .transportReset)
        }
    }

    @Test func notificationWaitTimesOutWithoutLeakingItsContinuation() async throws {
        let harness = try VirtioFSNotificationHarness(notificationBacklogLimit: 1)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: true)
        let barrier = try await harness.fs.submitInvalidation(.inode(nodeID: 9))

        do {
            try await barrier.wait(timeout: .milliseconds(20))
            Issue.record("notification wait unexpectedly completed")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .timedOut)
        }
        #expect(!barrier.isCompleted)

        // The timeout cancels and removes the internal waiter. A later reset can complete the
        // barrier without double-resuming that continuation.
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(barrier.isCompleted)
    }

    @Test func batchedHighLevelInvalidationKeepsRequestGateClosedAcrossEveryChunk() async throws {
        let harness = try VirtioFSNotificationHarness(notificationBacklogLimit: 1)
        try harness.prepareCoherentCachingEligibility()
        let fs = harness.fs

        let invalidation = Task {
            try await fs.invalidateAtomically(
                [
                    .delete(
                        parentNodeID: HostFS.rootNodeID,
                        childNodeID: 20,
                        name: "atomic.txt"
                    ),
                    .inode(nodeID: 20, offset: -1, length: 0),
                ],
                maximumBatchSize: 1,
                timeout: .seconds(2)
            )
        }
        #expect(await eventually {
            fs.requestPublicationGateClosed
                && (try? harness.usedIndex(queue: 1)) == 1
        })

        let blocked = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 419),
            queue: 2
        )
        #expect(await eventually { fs.deferredRequestQueueSnapshot.contains(2) })
        #expect(try harness.responseLength(blocked) == 0)

        // Ack the first one-item transport batch. The implementation must submit the second batch
        // without reopening request admission in between.
        let buffer = VirtioFS.requiredStableNotificationBufferCountForCaching - 1
        try harness.postWritableBuffer(
            queue: 1,
            descriptor: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching),
            address: harness.bufferAddress(buffer),
            slot: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching),
            index: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching + 1)
        )
        fs.handleKick(queue: 1, transport: harness.transport)
        #expect(await eventually { (try? harness.usedIndex(queue: 1)) == 2 })
        #expect(fs.requestPublicationGateClosed)
        #expect(try harness.responseLength(blocked) == 0)

        try harness.postWritableBuffer(
            queue: 1,
            descriptor: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching + 1),
            address: harness.bufferAddress(buffer),
            slot: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching + 1),
            index: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching + 2)
        )
        fs.handleKick(queue: 1, transport: harness.transport)
        try await invalidation.value

        let response = try harness.waitForFuseResponse(blocked)
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(!fs.requestPublicationGateClosed)
    }

    @Test func coherentCacheActivationRequiresCompleteNotificationHealthAndFuseInit() throws {
        let harness = try VirtioFSNotificationHarness()

        let initial = harness.fs.cacheActivationEligibility
        #expect(!initial.notificationFeatureNegotiated)
        #expect(!initial.notificationQueueReady)
        #expect(initial.stableNotificationBufferCount == 0)
        #expect(!initial.fuseInitCompleted)
        #expect(!initial.isEligible)
        #expect(harness.fs.activateCoherentCaching() == .ineligible(initial))
        #expect(!harness.fs.coherentCachingActive)

        try harness.configureQueue(1)
        try harness.configureQueue(2)
        for index in 0..<(VirtioFS.requiredStableNotificationBufferCountForCaching - 1) {
            try harness.postWritableBuffer(
                queue: 1,
                descriptor: UInt16(index),
                address: harness.bufferAddress(index),
                slot: UInt16(index),
                index: UInt16(index + 1)
            )
        }
        harness.setDriverReady(notifications: true)
        harness.fs.handleKick(queue: 1, transport: harness.transport)
        _ = try harness.performFuseRequest(makeFuseInitRequest(), queue: 2)

        let oneBufferShort = harness.fs.cacheActivationEligibility
        #expect(oneBufferShort.notificationFeatureNegotiated)
        #expect(oneBufferShort.notificationQueueReady)
        #expect(oneBufferShort.stableNotificationBufferCount == 15)
        #expect(oneBufferShort.fuseInitCompleted)
        #expect(!oneBufferShort.isEligible)
        #expect(harness.fs.activateCoherentCaching() == .ineligible(oneBufferShort))

        let last = VirtioFS.requiredStableNotificationBufferCountForCaching - 1
        try harness.postWritableBuffer(
            queue: 1,
            descriptor: UInt16(last),
            address: harness.bufferAddress(last),
            slot: UInt16(last),
            index: UInt16(last + 1)
        )
        harness.fs.handleKick(queue: 1, transport: harness.transport)

        let ready = harness.fs.cacheActivationEligibility
        #expect(ready.stableNotificationBufferCount == 16)
        #expect(ready.isEligible)
        #expect(harness.fs.activateCoherentCaching() == .activated)
        #expect(harness.fs.coherentCachingActive)

        try harness.write("cached", to: "cached.txt")
        let lookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 2, payload: Array("cached.txt\0".utf8)),
            queue: 2
        )
        let entry = Array(lookup.dropFirst(FuseOutHeader.byteCount))
        let nodeID = entry.leUInt64(at: 0)
        #expect(entry.leUInt64(at: 16) == VirtioFS.maximumCoherentCacheValiditySeconds)
        #expect(entry.leUInt64(at: 24) == VirtioFS.maximumCoherentCacheValiditySeconds)

        let getattr = try harness.performFuseRequest(
            makeFuseRequest(
                opcode: .getattr,
                unique: 3,
                nodeID: nodeID,
                payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
            ),
            queue: 2
        )
        #expect(Array(getattr.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0) == VirtioFS.maximumCoherentCacheValiditySeconds)

        let opened = try harness.performFuseRequest(
            makeFuseRequest(opcode: .open, unique: 4, nodeID: nodeID, payload: [UInt8](repeating: 0, count: 8)),
            queue: 2
        )
        #expect(Array(opened.dropFirst(FuseOutHeader.byteCount)).leUInt32(at: 8) == (1 << 5))
        let openedDir = try harness.performFuseRequest(
            makeFuseRequest(opcode: .opendir, unique: 5),
            queue: 2
        )
        #expect(Array(openedDir.dropFirst(FuseOutHeader.byteCount)).leUInt32(at: 8) == 0)

        let miss = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 6, payload: Array("missing.txt\0".utf8)),
            queue: 2
        )
        // Coherent mode grants a bounded negative dentry (nodeid 0) instead of a bare ENOENT.
        #expect(try FuseProtocol.decodeOutHeader(miss).error == 0)
        #expect(miss.count == FuseOutHeader.byteCount + 128)
        let missEntry = Array(miss.dropFirst(FuseOutHeader.byteCount))
        #expect(missEntry.leUInt64(at: 0) == 0)
        #expect(missEntry.leUInt64(at: 16) == FuseServer.negativeCoherentCacheValiditySeconds)
        #expect(missEntry.leUInt64(at: 24) == 0)

        harness.fs.deactivateCoherentCaching()
        #expect(!harness.fs.coherentCachingActive)
        let safeLookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 7, payload: Array("cached.txt\0".utf8)),
            queue: 2
        )
        let safeEntry = Array(safeLookup.dropFirst(FuseOutHeader.byteCount))
        #expect(safeEntry.leUInt64(at: 16) == 0)
        #expect(safeEntry.leUInt64(at: 24) == 0)

        #expect(harness.fs.activateCoherentCaching() == .activated)
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(!harness.fs.coherentCachingActive)
        let reset = harness.fs.cacheActivationEligibility
        #expect(!reset.notificationFeatureNegotiated)
        #expect(!reset.notificationQueueReady)
        #expect(reset.stableNotificationBufferCount == 0)
        #expect(!reset.fuseInitCompleted)
        #expect(!reset.isEligible)
    }

    @Test func interruptSuppressionDoesNotRollBackPublishedGrants() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.prepareCoherentCachingEligibility()
        try harness.suppressUsedInterrupts(queue: 2)

        // Virtqueue.push publishes the response either way; its Bool only reports whether the
        // guest wants an interrupt. Misreading suppression as a failed publish rolled back the
        // OPENDIR handle grant here, so the follow-up READDIRPLUS came back EBADF and enumeration
        // storms (rm -rf, npm scandir) saw truncated directories.
        let openedDir = try harness.performFuseRequest(
            makeFuseRequest(opcode: .opendir, unique: 30),
            queue: 2
        )
        #expect(try FuseProtocol.decodeOutHeader(openedDir).error == 0)
        let dirHandle = Array(openedDir.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)

        var readPayload = [UInt8]()
        readPayload.appendLE(dirHandle)
        readPayload.appendLE(UInt64(0))
        readPayload.appendLE(UInt32(4_096))
        readPayload.appendLE(UInt32(0))
        readPayload.appendLE(UInt64(0))
        readPayload.appendLE(UInt32(0))
        readPayload.appendLE(UInt32(0))
        let listing = try harness.performFuseRequest(
            makeFuseRequest(opcode: .readdirplus, unique: 31, payload: readPayload),
            queue: 2
        )
        #expect(try FuseProtocol.decodeOutHeader(listing).error == 0)
    }

    @Test func eventLossRecoversInPlaceWithHealthyNotificationChannel() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.write("stale", to: "stale.txt")
        try harness.write("alive", to: "alive.txt")
        try harness.prepareCoherentCachingEligibility()

        let guest = CoordinatorGuestFSEventSender()
        let fatals = CoordinatorFatalRecorder()
        let recoveries = CoordinatorFatalRecorder()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [HostShareCoherenceEndpoint(
                share: HostFSEventShare(hostRoot: harness.rootURL.path, guestRoot: "/workspace"),
                backend: harness.fs
            )],
            guestEvents: guest,
            onRecovered: { message in recoveries.append(message) },
            onFatalRecoveryRequired: { reason in fatals.append(reason) }
        )
        #expect(try await coordinator.activateCachingIfReady())
        #expect(harness.fs.coherentCachingActive)

        // Pin both identities through real lookups, then remove one behind FSEvents' back —
        // exactly the state a lost event window leaves behind.
        let staleLookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 21, payload: Array("stale.txt\0".utf8)),
            queue: 2
        )
        #expect(Array(staleLookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0) != 0)
        let aliveLookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 22, payload: Array("alive.txt\0".utf8)),
            queue: 2
        )
        #expect(Array(aliveLookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0) != 0)
        try harness.remove("stale.txt")

        let usedBefore = try harness.usedIndex(queue: 1)
        let dropped = HostFSEventChange(
            hostPath: harness.rootURL.path,
            guestPath: "/workspace",
            flags: UInt32(
                kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped
            ),
            eventID: 77
        )
        let done = CoordinatorFatalRecorder()
        let processing = Task {
            defer { done.append("done") }
            try await coordinator.process([dropped])
        }
        var pumps = 0
        while done.reasons.isEmpty, pumps < 512 {
            _ = try? harness.acknowledgeConsumedInvalidations()
            pumps += 1
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await processing.value

        #expect(fatals.reasons.isEmpty)
        #expect(await !coordinator.isDegraded)
        #expect(!harness.fs.requestPublicationGateClosed)
        // The recovery sweep actually published notifications and caching came back.
        #expect(try harness.usedIndex(queue: 1) > usedBefore)
        #expect(harness.fs.coherentCachingActive)
        #expect(recoveries.reasons.count == 1)
        #expect(recoveries.reasons[0].contains("caching reactivated"))
    }

    @Test func coordinatorNotificationTimeoutFailsClosedWithinOneSecondPolicy() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.write("old", to: "watched.txt")
        try harness.prepareCoherentCachingEligibility()
        #expect(!harness.fs.coherentCachingActive)
        #expect(HostShareCoherenceCoordinator.reverseInvalidationFailCloseDeadline == .seconds(1))

        let guest = CoordinatorGuestFSEventSender()
        let fatals = CoordinatorFatalRecorder()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [HostShareCoherenceEndpoint(
                share: HostFSEventShare(hostRoot: harness.rootURL.path, guestRoot: "/workspace"),
                backend: harness.fs
            )],
            guestEvents: guest,
            onFatalRecoveryRequired: { reason in fatals.append(reason) }
        )

        #expect(try await coordinator.activateCachingIfReady())
        #expect(harness.fs.coherentCachingActive)
        #expect(await guest.calls == [.init(operationID: 0, paths: [])])

        // Establish a positive inode/dentry whose one-second validity requires reverse
        // invalidation before a watcher wakeup may be delivered.
        let lookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 2, payload: Array("watched.txt\0".utf8)),
            queue: 2
        )
        let entry = Array(lookup.dropFirst(FuseOutHeader.byteCount))
        let nodeID = entry.leUInt64(at: 0)
        #expect(nodeID != 0)
        #expect(entry.leUInt64(at: 16) == VirtioFS.maximumCoherentCacheValiditySeconds)
        var openPayload = [UInt8]()
        openPayload.appendLE(UInt32(O_RDWR))
        openPayload.appendLE(UInt32(0))
        let opened = try harness.performFuseRequest(
            makeFuseRequest(opcode: .open, unique: 3, nodeID: nodeID, payload: openPayload),
            queue: 2
        )
        let handle = Array(opened.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        #expect(handle != 0)

        try harness.write("new", to: "watched.txt")
        let clock = ContinuousClock()
        let started = clock.now
        let change = HostFSEventChange(
            hostPath: harness.rootURL.appendingPathComponent("watched.txt").path,
            guestPath: "/workspace/watched.txt",
            flags: UInt32(kFSEventStreamEventFlagItemModified),
            eventID: 9
        )
        let processing = Task {
            try await coordinator.process([change])
        }
        #expect(await eventually { harness.fs.requestPublicationGateClosed })

        // Model delayed dirty-page writeback arriving after the host edit while the kernel refuses
        // to repost the invalidation buffer. It must remain unpublished both during the wait and
        // after the coordinator requests fatal recovery.
        let delayedWrite = try harness.enqueueFuseRequest(
            makeFuseWriteRequest(
                unique: 4,
                nodeID: nodeID,
                handle: handle,
                contents: Array("guest-late".utf8)
            ),
            queue: 2
        )
        #expect(await eventually { harness.fs.deferredRequestQueueSnapshot.contains(2) })
        #expect(try harness.responseLength(delayedWrite) == 0)

        try await processing.value
        let elapsed = started.duration(to: clock.now)

        #expect(await coordinator.isDegraded)
        #expect(!harness.fs.coherentCachingActive)
        #expect(fatals.reasons.count == 1)
        #expect(fatals.reasons[0].contains("reverse invalidation failed"))
        #expect(fatals.reasons[0].contains("acknowledgementTimedOut"))
        // Scheduler headroom still proves the old two-second data-loss window cannot regress
        // unnoticed: the policy fires at one second, well before that unsafe boundary.
        #expect(elapsed < .seconds(2))
        // A timed-out notification has uncertain page-cache state, so the coordinator must ask
        // for a VM restart without sending the guest watcher nudge or publishing delayed writes.
        #expect(await guest.calls == [.init(operationID: 0, paths: [])])
        #expect(harness.fs.requestPublicationGateClosed)
        #expect(try harness.responseLength(delayedWrite) == 0)
        #expect(try harness.contents(of: "watched.txt") == "new")

        // Even a late repost/ack racing recovery cannot reopen the one-way failure latch.
        try harness.acknowledgeFirstInvalidation()
        harness.fs.handleKick(queue: 2, transport: harness.transport)
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.fs.requestPublicationGateClosed)
        #expect(try harness.responseLength(delayedWrite) == 0)
        #expect(try harness.contents(of: "watched.txt") == "new")
    }

    @Test func coordinatorQuiescenceTimeoutRejectsBlockedActiveResponsePublication() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("old", to: "active-race.txt")
        try harness.prepareCoherentCachingEligibility()

        let guest = CoordinatorGuestFSEventSender()
        let fatals = CoordinatorFatalRecorder()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [HostShareCoherenceEndpoint(
                share: HostFSEventShare(hostRoot: harness.rootURL.path, guestRoot: "/workspace"),
                backend: harness.fs
            )],
            guestEvents: guest,
            onFatalRecoveryRequired: { reason in fatals.append(reason) }
        )
        #expect(try await coordinator.activateCachingIfReady())

        let lookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 420, payload: Array("active-race.txt\0".utf8)),
            queue: 2
        )
        let nodeID = Array(lookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        var openPayload = [UInt8]()
        openPayload.appendLE(UInt32(O_RDWR))
        openPayload.appendLE(UInt32(0))
        let opened = try harness.performFuseRequest(
            makeFuseRequest(opcode: .open, unique: 421, nodeID: nodeID, payload: openPayload),
            queue: 2
        )
        let handle = Array(opened.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)

        let activeEncoded = DispatchSemaphore(value: 0)
        let releaseActive = DispatchSemaphore(value: 0)
        let activePassedFence = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 422, opcode == .write else { return }
            activeEncoded.signal()
            releaseActive.wait()
            activePassedFence.signal()
        }
        let reachedLatchedGate = DispatchSemaphore(value: 0)
        harness.fs.requestGateDrainTestHook = { event in
            guard event == .deferred(queue: 2) else { return }
            reachedLatchedGate.signal()
        }
        defer {
            releaseActive.signal()
            harness.fs.responseFenceTestHook = nil
            harness.fs.requestGateDrainTestHook = nil
        }

        let usedBeforeActive = try harness.usedIndex(queue: 2)
        _ = try harness.enqueueFuseRequest(
            makeFuseWriteRequest(
                unique: 422,
                nodeID: nodeID,
                handle: handle,
                contents: Array("guest-preboundary".utf8)
            ),
            queue: 2
        )
        #expect(await semaphoreSignals(activeEncoded))
        #expect(try harness.usedIndex(queue: 2) == usedBeforeActive)

        // The guest write syscall has already run but its used-ring response is deliberately held.
        // A later host edit wins at the path. The deadline cannot undo that pre-boundary syscall;
        // it must establish fatal recovery and prevent the delayed response from publishing.
        try harness.write("host-new", to: "active-race.txt")
        let change = HostFSEventChange(
            hostPath: harness.rootURL.appendingPathComponent("active-race.txt").path,
            guestPath: "/workspace/active-race.txt",
            flags: UInt32(kFSEventStreamEventFlagItemModified),
            eventID: 10
        )
        let clock = ContinuousClock()
        let started = clock.now
        let processing = Task {
            try await coordinator.process([change])
        }
        #expect(await eventually { harness.fs.requestPublicationGateClosed })
        try await processing.value
        let elapsed = started.duration(to: clock.now)

        // The policy deadline is verified above as exactly one second. Allow bounded hosted-runner
        // scheduling headroom here while staying safely below the old two-second failure window.
        #expect(elapsed < .milliseconds(1_500))
        #expect(await coordinator.isDegraded)
        #expect(fatals.reasons.count == 1)
        #expect(fatals.reasons[0].contains("requestDrainTimedOut(activeRequests: 1)"))
        #expect(harness.fs.requestPublicationGateClosed)
        #expect(!harness.fs.coherentCachingActive)
        #expect(await guest.calls == [.init(operationID: 0, paths: [])])
        #expect(try harness.usedIndex(queue: 2) == usedBeforeActive)

        releaseActive.signal()
        #expect(await semaphoreSignals(activePassedFence))
        #expect(await semaphoreSignals(reachedLatchedGate))
        #expect(try harness.usedIndex(queue: 2) == usedBeforeActive)
        #expect(try harness.contents(of: "active-race.txt") == "host-new")
    }

    @Test func notificationQueueDisableAndReconfigureSynchronouslyRevokeCaching() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        try harness.configureQueue(2)
        for index in 0..<VirtioFS.requiredStableNotificationBufferCountForCaching {
            try harness.postWritableBuffer(
                queue: 1,
                descriptor: UInt16(index),
                address: harness.bufferAddress(index),
                slot: UInt16(index),
                index: UInt16(index + 1)
            )
        }
        harness.setDriverReady(notifications: true)
        harness.fs.handleKick(queue: 1, transport: harness.transport)
        _ = try harness.performFuseRequest(makeFuseInitRequest(), queue: 2)
        #expect(harness.fs.activateCoherentCaching() == .activated)
        #expect(VirtioFS.maximumCoherentCacheValiditySeconds == 30)

        let barrier = try await harness.fs.submitInvalidation(.inode(nodeID: 41))
        #expect(!barrier.isCompleted)

        harness.setQueueReady(1, false)

        #expect(barrier.isCompleted)
        do {
            try await barrier.wait()
            Issue.record("queue-disable barrier unexpectedly succeeded")
        } catch let error as VirtioFSNotificationError {
            #expect(error == .transportReset)
        }
        #expect(!harness.fs.coherentCachingActive)
        let disabled = harness.fs.cacheActivationEligibility
        #expect(disabled.notificationFeatureNegotiated)
        #expect(!disabled.notificationQueueReady)
        #expect(disabled.stableNotificationBufferCount == 0)
        #expect(disabled.fuseInitCompleted)
        #expect(!disabled.isEligible)

        try harness.configureQueue(1)
        for index in 0..<VirtioFS.requiredStableNotificationBufferCountForCaching {
            try harness.postWritableBuffer(
                queue: 1,
                descriptor: UInt16(index),
                address: harness.bufferAddress(index),
                slot: UInt16(index),
                index: UInt16(index + 1)
            )
        }
        harness.fs.handleKick(queue: 1, transport: harness.transport)

        let restored = harness.fs.cacheActivationEligibility
        #expect(restored.notificationQueueReady)
        #expect(restored.stableNotificationBufferCount == 16)
        #expect(restored.fuseInitCompleted)
        #expect(restored.isEligible)
        #expect(harness.fs.activateCoherentCaching() == .activated)

        // QueueReady=1 reconfigures an already-ready queue and must revoke the old epoch too.
        try harness.configureQueue(1)
        #expect(!harness.fs.coherentCachingActive)
        let reconfigured = harness.fs.cacheActivationEligibility
        #expect(reconfigured.notificationQueueReady)
        #expect(reconfigured.stableNotificationBufferCount == 0)
        #expect(!reconfigured.isEligible)
    }

    @Test func queueDisableNeutralizesMetadataResponseEncodedInPriorCacheEpoch() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("cached", to: "epoch.txt")
        try harness.prepareCoherentCaching()
        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 90, opcode == .lookup else { return }
            encoded.signal()
            release.wait()
        }

        let pending = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 90, payload: Array("epoch.txt\0".utf8)),
            queue: 2
        )
        #expect(await semaphoreSignals(encoded))

        harness.setQueueReady(1, false)
        #expect(!harness.fs.coherentCachingActive)
        release.signal()

        let response = try harness.waitForFuseResponse(pending)
        let entry = Array(response.dropFirst(FuseOutHeader.byteCount))
        #expect(entry.leUInt64(at: 0) != 0)
        #expect(entry.leUInt64(at: 16) == 0)
        #expect(entry.leUInt64(at: 24) == 0)
    }

    @Test func queueDisableNeutralizesLinkResponseEncodedInPriorCacheEpoch() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("source", to: "source.txt")
        try harness.prepareCoherentCaching()
        let lookup = try harness.performFuseRequest(
            makeFuseRequest(
                opcode: .lookup,
                unique: 91,
                payload: Array("source.txt\0".utf8)
            ),
            queue: 2
        )
        let sourceNodeID = Array(lookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)

        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 92, opcode == .link else { return }
            encoded.signal()
            release.wait()
        }
        defer {
            release.signal()
            harness.fs.responseFenceTestHook = nil
        }

        var linkPayload = [UInt8]()
        linkPayload.appendLE(sourceNodeID)
        linkPayload.append(contentsOf: "linked.txt\0".utf8)
        let pending = try harness.enqueueFuseRequest(
            makeFuseRequest(
                opcode: .link,
                unique: 92,
                payload: linkPayload
            ),
            queue: 2
        )
        #expect(await semaphoreSignals(encoded))

        // The LINK has already encoded fuse_entry_out with a one-second validity grant. A queue
        // epoch transition that overtakes publication must strip both validity fields.
        harness.setQueueReady(1, false)
        #expect(!harness.fs.coherentCachingActive)
        release.signal()

        let response = try harness.waitForFuseResponse(pending)
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        let entry = Array(response.dropFirst(FuseOutHeader.byteCount))
        #expect(entry.leUInt64(at: 0) == sourceNodeID)
        #expect(entry.leUInt64(at: 16) == 0)
        #expect(entry.leUInt64(at: 24) == 0)
    }

    @Test func lossMarkerFailStopSurvivesLateNotificationAckAndDeviceReset() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.prepareCoherentCaching()

        // Leave a low-level notification in flight so its later ack exercises the same gate state
        // that fatal recovery must permanently dominate.
        let barrier = try await harness.fs.submitInvalidation(.inode(nodeID: HostFS.rootNodeID))
        #expect(!barrier.isCompleted)

        let fatals = CoordinatorFatalRecorder()
        let coordinator = HostShareCoherenceCoordinator(
            endpoints: [HostShareCoherenceEndpoint(
                share: HostFSEventShare(hostRoot: harness.rootURL.path, guestRoot: "/workspace"),
                backend: harness.fs
            )],
            guestEvents: CoordinatorGuestFSEventSender(),
            onFatalRecoveryRequired: { reason in fatals.append(reason) }
        )
        try await coordinator.process([HostFSEventChange(
            hostPath: harness.rootURL.path,
            guestPath: "/workspace",
            flags: UInt32(
                kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagKernelDropped
            ),
            eventID: 500
        )])

        #expect(fatals.reasons.count == 1)
        #expect(harness.fs.requestPublicationGateClosed)
        let blocked = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 501),
            queue: 2
        )
        #expect(await eventually { harness.fs.deferredRequestQueueSnapshot.contains(2) })
        #expect(try harness.responseLength(blocked) == 0)

        try harness.acknowledgeFirstInvalidation()
        try await barrier.wait()
        #expect(harness.fs.requestPublicationGateClosed)
        #expect(try harness.responseLength(blocked) == 0)

        harness.transport.write(offset: 0x070, value: 0, width: 4)
        #expect(harness.fs.requestPublicationGateClosed)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let afterReset = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 502),
            queue: 1
        )
        #expect(await eventually { harness.fs.deferredRequestQueueSnapshot.contains(1) })
        #expect(try harness.responseLength(afterReset) == 0)
    }

    @Test func invalidationFenceLetsLockHoldingLookupDrainBeforeDeleteAck() async throws {
        let harness = try VirtioFSNotificationHarness(requestQueueCount: 2, inlineRequests: false)
        try harness.write("present", to: "race.txt")
        try harness.prepareCoherentCaching()

        let primed = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 10, payload: Array("race.txt\0".utf8)),
            queue: 2
        )
        let nodeID = Array(primed.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 100, opcode == .lookup else { return }
            encoded.signal()
            release.wait()
        }

        let oldPending = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 100, payload: Array("race.txt\0".utf8)),
            queue: 2
        )
        #expect(await semaphoreSignals(encoded))

        try harness.remove("race.txt")
        let fs = harness.fs
        let invalidation = Task {
            try await fs.submitInvalidation(
                .delete(parentNodeID: HostFS.rootNodeID, childNodeID: nodeID, name: "race.txt")
            )
        }
        let gateClosed = await eventually { fs.requestPublicationGateClosed }
        #expect(gateClosed)

        let newPending = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 101, payload: Array("race.txt\0".utf8)),
            queue: 3
        )
        // LOOKUP may hold the parent VFS lock that FUSE_NOTIFY_DELETE needs. It must drain across
        // the write fence; Linux's writer ordering makes the notification invalidate afterward.
        // The drained miss is a bounded negative dentry; the queued DELETE retires it in order.
        let newResponse = try harness.waitForFuseResponse(newPending)
        #expect(try FuseProtocol.decodeOutHeader(newResponse).error == 0)
        #expect(newResponse.count == FuseOutHeader.byteCount + 128)
        #expect(Array(newResponse.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0) == 0)

        release.signal()
        let oldResponse = try harness.waitForFuseResponse(oldPending)
        #expect(try FuseProtocol.decodeOutHeader(oldResponse).error == 0)
        #expect(Array(oldResponse.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0) == nodeID)

        let barrier = try await invalidation.value
        try harness.acknowledgeFirstInvalidation()
        try await barrier.wait()
    }

    @Test func invalidationFenceLetsFolioHoldingReadDrainBeforeInodeAck() async throws {
        let harness = try VirtioFSNotificationHarness(requestQueueCount: 2, inlineRequests: false)
        try harness.write("old-data", to: "read-race.txt")
        try harness.prepareCoherentCaching()

        let lookup = try harness.performFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 20, payload: Array("read-race.txt\0".utf8)),
            queue: 2
        )
        let nodeID = Array(lookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        let opened = try harness.performFuseRequest(
            makeFuseRequest(
                opcode: .open,
                unique: 21,
                nodeID: nodeID,
                payload: [UInt8](repeating: 0, count: 8)
            ),
            queue: 2
        )
        let handle = Array(opened.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 200, opcode == .read else { return }
            encoded.signal()
            release.wait()
        }

        let oldPending = try harness.enqueueFuseRequest(
            makeFuseReadRequest(unique: 200, nodeID: nodeID, handle: handle, count: 8),
            queue: 2
        )
        #expect(await semaphoreSignals(encoded))

        try harness.write("new-data", to: "read-race.txt")
        let fs = harness.fs
        let invalidation = Task {
            try await fs.submitInvalidation(.inode(nodeID: nodeID))
        }
        let gateClosed = await eventually { fs.requestPublicationGateClosed }
        #expect(gateClosed)

        let newPending = try harness.enqueueFuseRequest(
            makeFuseReadRequest(unique: 201, nodeID: nodeID, handle: handle, count: 8),
            queue: 3
        )
        // READ may own the folio lock that INVAL_INODE needs. The response must drain so the fair
        // invalidation writer can acquire and evict the folio rather than deadlocking on the host.
        let newResponse = try harness.waitForFuseResponse(newPending)
        #expect(String(decoding: newResponse.dropFirst(FuseOutHeader.byteCount), as: UTF8.self) == "new-data")

        release.signal()
        let oldResponse = try harness.waitForFuseResponse(oldPending)
        #expect(String(decoding: oldResponse.dropFirst(FuseOutHeader.byteCount), as: UTF8.self) == "old-data")

        let barrier = try await invalidation.value
        try harness.acknowledgeFirstInvalidation()
        try await barrier.wait()
    }

    @Test func requestQueueCountIsClampedToDeviceLimits() throws {
        let root = try TestVirtioFSRoot()
        let host = try HostFS(rootPath: root.url.path)

        #expect(try VirtioFS(tag: "low", hostFS: host, requestQueueCount: 0).requestQueueCount == 1)
        #expect(try VirtioFS(tag: "high", hostFS: host, requestQueueCount: 99).requestQueueCount == 16)
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

    func write(_ contents: String, to relativePath: String) throws {
        try Data(contents.utf8).write(to: url.appendingPathComponent(relativePath))
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url.appendingPathComponent(relativePath))
    }
}

private final class VirtioFSNotificationHarness {
    private static let base: UInt64 = 0x8000_0000
    // Queue and buffer fixtures use fixed offsets through 0x73xxx on both host architectures.
    private static let memorySize: UInt64 = 0x10_0000
    private let root: TestVirtioFSRoot
    let hostFS: HostFS
    let fs: VirtioFS
    let memory: GuestMemory
    let transport: VirtioMMIOTransport
    private let requestIndexLock = NSLock()
    private var requestAvailIndices: [Int: UInt16] = [:]
    private var lastSeenNotificationUsedIndex: UInt16 = 0
    private var notificationAvailIndex: UInt16 = UInt16(
        VirtioFS.requiredStableNotificationBufferCountForCaching
    )

    var rootURL: URL { root.url }

    init(
        notificationBacklogLimit: Int = 256,
        requestQueueCount: Int = 1,
        inlineRequests: Bool? = nil
    ) throws {
        root = try TestVirtioFSRoot()
        hostFS = try HostFS(rootPath: root.url.path)
        fs = try VirtioFS(
            tag: "home",
            hostFS: hostFS,
            requestQueueCount: requestQueueCount,
            notificationBacklogLimit: notificationBacklogLimit,
            inlineRequests: inlineRequests
        )
        memory = try GuestMemory(guestBase: Self.base, size: Self.memorySize)
        transport = VirtioMMIOTransport(
            baseAddress: 0x0A00_0000,
            backend: fs,
            memory: memory,
            interrupt: {}
        )
    }

    func setDriverReady(notifications: Bool) {
        if notifications {
            transport.write(offset: 0x024, value: 0, width: 4)
            transport.write(offset: 0x020, value: VirtioFS.notificationFeature, width: 4)
        }
        transport.write(offset: 0x070, value: 0x4, width: 4)
    }

    func configureQueue(_ queue: Int) throws {
        let layout = queueLayout(queue)
        requestIndexLock.withLock { requestAvailIndices[queue] = 0 }
        try memory.write(UInt16(0), at: layout.avail)
        try memory.write(UInt16(0), at: layout.avail + 2)
        try memory.write(UInt16(0), at: layout.used + 2)
        transport.write(offset: 0x030, value: UInt64(queue), width: 4)
        transport.write(offset: 0x038, value: 32, width: 4)
        transport.write(offset: 0x080, value: layout.descriptor & 0xFFFF_FFFF, width: 4)
        transport.write(offset: 0x084, value: layout.descriptor >> 32, width: 4)
        transport.write(offset: 0x090, value: layout.avail & 0xFFFF_FFFF, width: 4)
        transport.write(offset: 0x094, value: layout.avail >> 32, width: 4)
        transport.write(offset: 0x0A0, value: layout.used & 0xFFFF_FFFF, width: 4)
        transport.write(offset: 0x0A4, value: layout.used >> 32, width: 4)
        transport.write(offset: 0x044, value: 1, width: 4)
    }

    func setQueueReady(_ queue: Int, _ ready: Bool) {
        transport.write(offset: 0x030, value: UInt64(queue), width: 4)
        transport.write(offset: 0x044, value: ready ? 1 : 0, width: 4)
    }

    func postWritableBuffer(
        queue: Int,
        descriptor: UInt16,
        address: UInt64,
        slot: UInt16,
        index: UInt16
    ) throws {
        let layout = queueLayout(queue)
        let descriptorAddress = layout.descriptor + UInt64(descriptor) * 16
        try memory.write(address, at: descriptorAddress)
        try memory.write(UInt32(VirtioFS.notificationBufferSize), at: descriptorAddress + 8)
        try memory.write(UInt16(0x2), at: descriptorAddress + 12)
        try memory.write(UInt16(0), at: descriptorAddress + 14)
        try memory.write(descriptor, at: layout.avail + 4 + UInt64(slot) * 2)
        try memory.write(index, at: layout.avail + 2)
    }

    func bufferAddress(_ index: Int) -> UInt64 {
        Self.base + 0x20_000 + UInt64(index) * UInt64(VirtioFS.notificationBufferSize)
    }

    func usedIndex(queue: Int) throws -> UInt16 {
        try memory.read(UInt16.self, at: queueLayout(queue).used + 2)
    }

    /// Sets VRING_AVAIL_F_NO_INTERRUPT, exactly what the Linux driver does while it polls the
    /// used ring during an I/O storm. Responses are still published; only the interrupt is skipped.
    func suppressUsedInterrupts(queue: Int) throws {
        try memory.write(UInt16(1), at: queueLayout(queue).avail)
    }

    func write(_ contents: String, to relativePath: String) throws {
        try root.write(contents, to: relativePath)
    }

    func contents(of relativePath: String) throws -> String {
        try String(contentsOf: root.url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func remove(_ relativePath: String) throws {
        try root.remove(relativePath)
    }

    func prepareCoherentCaching() throws {
        try prepareCoherentCachingEligibility()
        guard fs.activateCoherentCaching() == .activated else {
            throw VirtioFSHarnessError.cacheActivationFailed
        }
    }

    func prepareCoherentCachingEligibility() throws {
        try configureQueue(1)
        for queue in 2..<(2 + fs.requestQueueCount) {
            try configureQueue(queue)
        }
        for index in 0..<VirtioFS.requiredStableNotificationBufferCountForCaching {
            try postWritableBuffer(
                queue: 1,
                descriptor: UInt16(index),
                address: bufferAddress(index),
                slot: UInt16(index),
                index: UInt16(index + 1)
            )
        }
        setDriverReady(notifications: true)
        fs.handleKick(queue: 1, transport: transport)
        _ = try performFuseRequest(makeFuseInitRequest(), queue: 2)
        let deadline = Date().addingTimeInterval(1)
        while !fs.cacheActivationEligibility.fuseInitCompleted, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.0001)
        }
        guard fs.cacheActivationEligibility.isEligible else {
            throw VirtioFSHarnessError.cacheActivationFailed
        }
    }

    func responseLength(_ pending: PendingFuseRequest) throws -> UInt32 {
        try memory.read(UInt32.self, at: pending.responseAddress)
    }

    func encodedResponse(_ pending: PendingFuseRequest) throws -> [UInt8] {
        let length = try responseLength(pending)
        guard length >= UInt32(FuseOutHeader.byteCount),
              length <= UInt32(pending.responseCapacity) else {
            throw VirtioFSHarnessError.invalidResponseLength(length)
        }
        return try memory.readBytes(at: pending.responseAddress, count: Int(length))
    }

    /// Acknowledges every notification the device has consumed so far, exactly like the real
    /// guest driver: read queue 1's used ring for consumed descriptor heads and repost those same
    /// buffer addresses. Supports arbitrary-length streams such as a loss-recovery sweep.
    @discardableResult
    func acknowledgeConsumedInvalidations() throws -> Int {
        let layout = queueLayout(1)
        let used = try memory.read(UInt16.self, at: layout.used + 2)
        var acked = 0
        while lastSeenNotificationUsedIndex != used {
            let slot = UInt64(lastSeenNotificationUsedIndex % 32)
            let head = try memory.read(UInt32.self, at: layout.used + 4 + slot * 8)
            let address = try memory.read(UInt64.self, at: layout.descriptor + UInt64(head) * 16)
            lastSeenNotificationUsedIndex &+= 1
            notificationAvailIndex &+= 1
            let ringPosition = UInt16((UInt64(notificationAvailIndex) - 1) % 32)
            try postWritableBuffer(
                queue: 1,
                descriptor: ringPosition,
                address: address,
                slot: ringPosition,
                index: notificationAvailIndex
            )
            acked += 1
        }
        if acked > 0 {
            fs.handleKick(queue: 1, transport: transport)
        }
        return acked
    }

    func acknowledgeFirstInvalidation() throws {
        let lastBuffer = VirtioFS.requiredStableNotificationBufferCountForCaching - 1
        let nextIndex = UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching + 1)
        try postWritableBuffer(
            queue: 1,
            descriptor: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching),
            address: bufferAddress(lastBuffer),
            slot: UInt16(VirtioFS.requiredStableNotificationBufferCountForCaching),
            index: nextIndex
        )
        fs.handleKick(queue: 1, transport: transport)
    }

    func performFuseRequest(
        _ request: [UInt8],
        queue: Int,
        responseCapacity: Int = 512
    ) throws -> [UInt8] {
        try waitForFuseResponse(enqueueFuseRequest(
            request,
            queue: queue,
            responseCapacity: responseCapacity
        ))
    }

    func enqueueFuseRequest(
        _ request: [UInt8],
        queue: Int,
        kick: Bool = true,
        responseCapacity: Int = 512
    ) throws -> PendingFuseRequest {
        let layout = queueLayout(queue)
        let requestAddress = Self.base + 0x60_000 + UInt64(queue) * 0x1_000
        let responseAddress = Self.base + 0x70_000 + UInt64(queue) * 0x1_000
        try memory.write(request, at: requestAddress)
        try memory.write([UInt8](repeating: 0, count: responseCapacity), at: responseAddress)

        try memory.write(requestAddress, at: layout.descriptor)
        try memory.write(UInt32(request.count), at: layout.descriptor + 8)
        try memory.write(UInt16(0x1), at: layout.descriptor + 12) // VIRTQ_DESC_F_NEXT
        try memory.write(UInt16(1), at: layout.descriptor + 14)

        try memory.write(responseAddress, at: layout.descriptor + 16)
        try memory.write(UInt32(responseCapacity), at: layout.descriptor + 24)
        try memory.write(UInt16(0x2), at: layout.descriptor + 28) // VIRTQ_DESC_F_WRITE
        try memory.write(UInt16(0), at: layout.descriptor + 30)

        let next = requestIndexLock.withLock {
            let next = (requestAvailIndices[queue] ?? 0) &+ 1
            requestAvailIndices[queue] = next
            return next
        }
        let slot = (next &- 1) % 32
        try memory.write(UInt16(0), at: layout.avail + 4 + UInt64(slot) * 2)
        try memory.write(next, at: layout.avail + 2)
        if kick {
            fs.handleKick(queue: queue, transport: transport)
        }

        return PendingFuseRequest(
            queue: queue,
            expectedUsedIndex: next,
            responseAddress: responseAddress,
            responseCapacity: responseCapacity
        )
    }

    func waitForFuseResponse(
        _ pending: PendingFuseRequest,
        timeout: TimeInterval = 2
    ) throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let usedIndex = try memory.read(UInt16.self, at: queueLayout(pending.queue).used + 2)
            guard usedIndex == pending.expectedUsedIndex else {
                Thread.sleep(forTimeInterval: 0.0001)
                continue
            }
            let length = try memory.read(UInt32.self, at: pending.responseAddress)
            if length >= UInt32(FuseOutHeader.byteCount), length <= UInt32(pending.responseCapacity) {
                return try memory.readBytes(at: pending.responseAddress, count: Int(length))
            }
            Thread.sleep(forTimeInterval: 0.0001)
        }
        throw VirtioFSHarnessError.responseTimedOut
    }

    private func queueLayout(_ queue: Int) -> (descriptor: UInt64, avail: UInt64, used: UInt64) {
        let start = Self.base + 0x1000 + UInt64(queue - 1) * 0x4000
        return (start, start + 0x1000, start + 0x2000)
    }
}

private enum VirtioFSHarnessError: Error {
    case invalidResponseLength(UInt32)
    case responseTimedOut
    case cacheActivationFailed
}

private struct PendingFuseRequest: Sendable {
    let queue: Int
    let expectedUsedIndex: UInt16
    let responseAddress: UInt64
    let responseCapacity: Int
}

private actor CoordinatorGuestFSEventSender: GuestFSEventSending {
    struct Call: Equatable, Sendable {
        var operationID: UInt64
        var paths: [String]
    }

    private(set) var calls = [Call]()

    func send(operationID: UInt64, paths: [String]) async throws -> GuestFSEventBatchResult {
        calls.append(Call(operationID: operationID, paths: paths))
        return GuestFSEventBatchResult(pathCount: UInt32(paths.count), failedIndices: [])
    }
}

private final class CoordinatorFatalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [String]()

    var reasons: [String] { lock.withLock { storage } }

    func append(_ reason: String) {
        lock.withLock { storage.append(reason) }
    }
}

private func makeFuseInitRequest() -> [UInt8] {
    var payload = [UInt8]()
    payload.appendLE(UInt32(7))
    payload.appendLE(UInt32(38))
    payload.appendLE(UInt32(131_072))
    payload.appendLE(UInt32(0))
    return makeFuseRequest(opcode: .initOp, unique: 1, payload: payload)
}

private func makeFuseReadRequest(
    unique: UInt64,
    nodeID: UInt64,
    handle: UInt64,
    count: UInt32
) -> [UInt8] {
    var payload = [UInt8]()
    payload.appendLE(handle)
    payload.appendLE(UInt64(0))
    payload.appendLE(count)
    payload.appendLE(UInt32(0))
    payload.appendLE(UInt64(0))
    payload.appendLE(UInt32(0))
    payload.appendLE(UInt32(0))
    return makeFuseRequest(opcode: .read, unique: unique, nodeID: nodeID, payload: payload)
}

private func makeFuseWriteRequest(
    unique: UInt64,
    nodeID: UInt64,
    handle: UInt64,
    contents: [UInt8]
) -> [UInt8] {
    var payload = [UInt8]()
    payload.appendLE(handle)
    payload.appendLE(UInt64(0))
    payload.appendLE(UInt32(contents.count))
    payload.appendLE(UInt32(0))
    payload.appendLE(UInt64(0))
    payload.appendLE(UInt32(0))
    payload.appendLE(UInt32(0))
    payload.append(contentsOf: contents)
    return makeFuseRequest(opcode: .write, unique: unique, nodeID: nodeID, payload: payload)
}

private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func semaphoreSignals(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval = .seconds(2)
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}

private func makeFuseRequest(
    opcode: FuseOpcode,
    unique: UInt64,
    nodeID: UInt64 = HostFS.rootNodeID,
    payload: [UInt8] = []
) -> [UInt8] {
    FuseProtocol.encodeInHeader(FuseInHeader(
        length: UInt32(FuseInHeader.byteCount + payload.count),
        opcode: opcode.rawValue,
        unique: unique,
        nodeID: nodeID,
        uid: 1_000,
        gid: 1_000,
        pid: 42
    )) + payload
}
