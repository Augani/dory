import CoreServices
import DoryFSWorkerContracts
import Foundation
import Testing
@testable import DoryFSWorkerServiceCore
@testable import DoryHV

@Suite(.serialized)
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

    @Test func initialStatusZeroBeforeDriverReadyKeepsWorkerGenerationActive() async throws {
        let harness = try VirtioFSNotificationHarness()

        // Linux begins discovery by writing zero even though the transport is already reset. This
        // is not a reset of an established FUSE connection and must not consume the worker's
        // one-shot bootstrap generation.
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        try await Task.sleep(for: .milliseconds(20))

        #expect(await harness.broker.snapshot().state == .active)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let response = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .statfs, unique: 400),
            queue: 1
        )
        #expect(try FuseProtocol.decodeOutHeader(
            harness.waitForFuseResponse(response)
        ).unique == 400)
    }

    @Test func committedDestroyClassifiesFollowingDeviceResetAsConnectionTeardown() async throws {
        let events = WorkerLifecycleRecorder()
        let harness = try VirtioFSNotificationHarness(
            onWorkerLifecycle: { events.record($0) }
        )
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)

        let destroy = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .destroy, unique: 403, nodeID: 0),
            queue: 1,
            responseCapacity: FuseOutHeader.byteCount
        )
        #expect(
            try FuseProtocol.decodeOutHeader(harness.waitForFuseResponse(destroy)).error == 0
        )
        #expect(await eventually { await harness.broker.snapshot().pendingPublications == 0 })
        try await Task.sleep(for: .milliseconds(20))

        harness.transport.write(offset: 0x070, value: 0, width: 4)

        #expect(await eventually { !events.snapshot.isEmpty })
        #expect(events.snapshot == [.connectionTeardown])
        #expect(await harness.broker.snapshot().state == .drained)
    }

    @Test func establishedResetWithoutDestroyRemainsTypedWorkerFailure() async throws {
        let events = WorkerLifecycleRecorder()
        let harness = try VirtioFSNotificationHarness(
            onWorkerLifecycle: { events.record($0) }
        )
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)

        harness.transport.write(offset: 0x070, value: 0, width: 4)

        #expect(await eventually { !events.snapshot.isEmpty })
        guard case .failure(let reason) = events.snapshot.first else {
            Issue.record("established reset was not reported as a worker failure")
            return
        }
        #expect(reason.contains("device reset"))
        #expect(await harness.broker.snapshot().state == .invalidated)
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
        #expect(harness.fs.statistics == VirtioFSStatistics(
            invalidations: 0,
            invalidationFailures: 1,
            invalidationFailureLatched: false
        ))
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
        #expect(harness.fs.statistics == VirtioFSStatistics(
            invalidations: 0,
            invalidationFailures: 1,
            invalidationFailureLatched: true
        ))

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
        try await harness.prepareCoherentCachingEligibility()

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
        let deferredSubmission = Task<PendingFuseRequest, any Error> {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try harness.enqueueFuseRequest(
                            makeFuseRequest(opcode: .statfs, unique: 411),
                            queue: 2
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
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
        let deferred = try await deferredSubmission.value

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

    @Test func resetAndQueueReconfigureRejectResponseFromOldRequestEpochAndInvalidatesWorker() async throws {
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

        // Reset invalidates the popped request's epoch and the worker generation. Rebuilding
        // QueueReady cannot make the retired broker reusable; the VM owner must replace the
        // backend after the fail-stop callback. The old response is discarded when host work
        // resumes.
        harness.transport.write(offset: 0x070, value: 0, width: 4)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        release.signal()

        #expect(await eventually {
            await harness.broker.snapshot().state == .invalidated
        })
        #expect(try harness.usedIndex(queue: 1) == 0)
    }

    @Test func queueEpochDropRollsBackAnUnpublishedLookupReference() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("payload", to: "dropped.txt")
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let encoded = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let hostResponse = FuseResponseRecorder()
        harness.fs.hostResponseSnapshotTestHook = { header, opcode, response in
            guard header.unique == 303, opcode == .lookup else { return }
            hostResponse.store(response)
        }
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 303, opcode == .lookup else { return }
            encoded.signal()
            release.wait()
        }
        defer {
            release.signal()
            harness.fs.responseFenceTestHook = nil
            harness.fs.hostResponseSnapshotTestHook = nil
        }

        _ = try harness.enqueueFuseRequest(
            makeFuseRequest(opcode: .lookup, unique: 303, payload: Array("dropped.txt\0".utf8)),
            queue: 1
        )
        #expect(await semaphoreSignals(encoded))
        let encodedLookup = try #require(hostResponse.value)
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

    @Test func undersizedResponseRejectsBeforeLookupGrantAndPublishesCompleteEIOHeader() throws {
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
        #expect(harness.fs.frontendStatistics.executedRequests == 0)
    }

    @Test func deviceResetWaitsForDroppedOpenThenInvalidatesTheWorkerGeneration() async throws {
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
        let hostResponse = FuseResponseRecorder()
        harness.fs.hostResponseSnapshotTestHook = { header, opcode, response in
            guard header.unique == 306, opcode == .open else { return }
            hostResponse.store(response)
        }
        harness.fs.responseFenceTestHook = { header, opcode in
            guard header.unique == 306, opcode == .open else { return }
            encoded.signal()
            release.wait()
        }
        defer {
            release.signal()
            harness.fs.responseFenceTestHook = nil
            harness.fs.hostResponseSnapshotTestHook = nil
        }

        _ = try harness.enqueueFuseRequest(
            makeFuseRequest(
                opcode: .open,
                unique: 306,
                nodeID: oldNodeID,
                payload: [UInt8](repeating: 0, count: 8)
            ),
            queue: 1
        )
        #expect(await semaphoreSignals(encoded))
        let encodedOpen = try #require(hostResponse.value)
        let staleHandle = Array(encodedOpen.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        #expect(staleHandle != 0)

        harness.transport.write(offset: 0x070, value: 0, width: 4)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        release.signal()

        #expect(await eventually {
            await harness.broker.snapshot().state == .invalidated
        })
        #expect(await eventually {
            do {
                _ = try harness.hostFS.cachedAttributes(nodeID: oldNodeID)
                return false
            } catch HostFSError.notFound {
                return true
            } catch {
                return false
            }
        })
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
        #expect(harness.fs.statistics == VirtioFSStatistics(
            invalidations: 1,
            invalidationFailures: 0,
            invalidationFailureLatched: false
        ))
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
        try await harness.prepareCoherentCachingEligibility()
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

    @Test func positiveCachingRemainsFailClosedWithHealthyNotifications() async throws {
        let harness = try VirtioFSNotificationHarness()
        let initial = harness.fs.cacheActivationEligibility
        #expect(!initial.isEligible)
        #expect(harness.fs.activateCoherentCaching() == .ineligible(initial))
        #expect(!harness.fs.coherentCachingActive)

        try await harness.prepareCoherentCachingEligibility()
        let healthy = harness.fs.cacheActivationEligibility
        #expect(healthy.isEligible)
        #expect(harness.fs.activateCoherentCaching() == .ineligible(healthy))
        #expect(!harness.fs.coherentCachingActive)

        try harness.write("uncached", to: "uncached.txt")
        let lookup = try harness.performFuseRequest(
            makeFuseRequest(
                opcode: .lookup,
                unique: 6,
                payload: Array("uncached.txt\\0".utf8)
            ),
            queue: 2
        )
        let entry = Array(lookup.dropFirst(FuseOutHeader.byteCount))
        #expect(entry.leUInt64(at: 16) == 0)
        #expect(entry.leUInt64(at: 24) == 0)
        #expect(VirtioFS.maximumCoherentCacheValiditySeconds == 0)
    }

    @Test func cacheReadinessWaitsForCommittedFuseInitPublication() async throws {
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

        let acknowledgementEntered = DispatchSemaphore(value: 0)
        let releaseAcknowledgement = DispatchSemaphore(value: 0)
        harness.workerChannel.beforePublicationAcknowledgementTestHook = { publication, committed in
            guard publication.correlationID == 1, committed else { return }
            acknowledgementEntered.signal()
            releaseAcknowledgement.wait()
        }
        defer {
            releaseAcknowledgement.signal()
            harness.workerChannel.beforePublicationAcknowledgementTestHook = nil
        }

        let pending = try harness.enqueueFuseRequest(makeFuseInitRequest(), queue: 2)
        #expect(await semaphoreSignals(acknowledgementEntered))

        // The successful FUSE_INIT response is already guest-visible, but the broker acknowledgement
        // is deliberately blocked. Advertising readiness here would let a failed acknowledgement
        // enable caching for a frontend generation that is about to fail-stop.
        let response = try harness.waitForFuseResponse(pending)
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        let awaitingCommit = harness.fs.cacheActivationEligibility
        #expect(awaitingCommit.notificationFeatureNegotiated)
        #expect(awaitingCommit.notificationQueueReady)
        #expect(
            awaitingCommit.stableNotificationBufferCount
                == VirtioFS.requiredStableNotificationBufferCountForCaching
        )
        #expect(!awaitingCommit.fuseInitCompleted)
        #expect(!awaitingCommit.isEligible)

        let committedEligibility = Task {
            try await harness.waitForCommittedCacheActivationEligibility()
        }
        releaseAcknowledgement.signal()

        let eligible = try await committedEligibility.value
        #expect(eligible.fuseInitCompleted)
        #expect(eligible.isEligible)
        #expect(await harness.broker.snapshot().pendingPublications == 0)
    }

    @Test func interruptSuppressionDoesNotRollBackPublishedGrants() async throws {
        let harness = try VirtioFSNotificationHarness()
        try await harness.prepareCoherentCachingEligibility()
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
            queue: 2,
            responseCapacity: FuseOutHeader.byteCount + 4_096
        )
        #expect(try FuseProtocol.decodeOutHeader(listing).error == 0)
    }

    @Test func notificationQueueDisableAndReconfigureSynchronouslyRevokeThePublicationEpoch() async throws {
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
        let healthy = try await harness.waitForCommittedCacheActivationEligibility()
        #expect(healthy.isEligible)
        #expect(harness.fs.activateCoherentCaching() == .ineligible(healthy))
        #expect(!harness.fs.coherentCachingActive)

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
        #expect(harness.fs.activateCoherentCaching() == .ineligible(restored))
        #expect(!harness.fs.coherentCachingActive)

        // QueueReady=1 reconfigures an already-ready queue and must revoke the old epoch too.
        try harness.configureQueue(1)
        #expect(!harness.fs.coherentCachingActive)
        let reconfigured = harness.fs.cacheActivationEligibility
        #expect(reconfigured.notificationQueueReady)
        #expect(reconfigured.stableNotificationBufferCount == 0)
        #expect(!reconfigured.isEligible)
    }

    @Test func invalidationFenceLetsLockHoldingLookupDrainBeforeDeleteAck() async throws {
        let harness = try VirtioFSNotificationHarness(requestQueueCount: 2, inlineRequests: false)
        try harness.write("present", to: "race.txt")
        try await harness.prepareCoherentCaching()

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
        // Positive and negative metadata caching are fail-closed, so the drained miss is ENOENT
        // rather than a cached negative-entry grant.
        let newResponse = try harness.waitForFuseResponse(newPending)
        #expect(try FuseProtocol.decodeOutHeader(newResponse).error == -ENOENT)
        #expect(newResponse.count == FuseOutHeader.byteCount)

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
        try await harness.prepareCoherentCaching()

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

        #expect(VirtioFS.defaultRequestQueueCount(activeProcessorCount: 0) == 1)
        #expect(VirtioFS.defaultRequestQueueCount(activeProcessorCount: 4) == 4)
        #expect(VirtioFS.defaultRequestQueueCount(activeProcessorCount: 64) == 8)
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

}

@Suite("VirtioFS frontend admission", .serialized)
struct VirtioFSFrontendAdmissionTests {
    @Test func rejectsMalformedDirectionOrderAndZeroLengthDescriptors() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let request = makeFuseRequest(opcode: .statfs, unique: 700)
        let malformed: [[FuseDescriptorFixture]] = [
            [.writable(FuseOutHeader.byteCount)],
            [.writable(FuseOutHeader.byteCount), .readable(request)],
            [
                .readable(Array(request[..<20])),
                .writable(FuseOutHeader.byteCount),
                .readable(Array(request[20...])),
            ],
            [
                .readable(request),
                .zeroLength(deviceWritable: false),
                .writable(FuseOutHeader.byteCount),
            ],
        ]

        for descriptors in malformed {
            let pending = try harness.enqueueDescriptorChain(descriptors, queue: 1)
            try harness.waitForUsed(pending)
            #expect(try harness.usedLength(pending) == 0)
        }
        #expect(harness.fs.frontendStatistics == VirtioFSFrontendStatistics(
            rejectedRequests: 4,
            executedRequests: 0,
            terminalQueueFaults: 0
        ))

        let valid = try harness.enqueueDescriptorChain([
            .readable(Array(request[..<20])),
            .readable(Array(request[20...])),
            .writable(FuseOutHeader.byteCount + 80),
        ], queue: 1)
        let response = try harness.waitForFuseResponse(valid)
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(harness.fs.frontendStatistics.executedRequests == 1)
    }

    @Test func requiresHeaderLengthToEqualTheCompleteReadablePrefix() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        var request = makeFuseRequest(opcode: .statfs, unique: 701)
        overwriteFuseLength(&request, with: UInt32(request.count + 1))

        let pending = try harness.enqueueDescriptorChain([
            .readable(Array(request[..<24])),
            .readable(Array(request[24...])),
            .writable(FuseOutHeader.byteCount),
        ], queue: 1)
        let response = try harness.waitForFuseResponse(pending)
        let header = try FuseProtocol.decodeOutHeader(response)
        #expect(header.unique == 701)
        #expect(header.error == -FuseProtocol.linuxErrno(EINVAL))
        #expect(harness.fs.frontendStatistics.rejectedRequests == 1)
        #expect(harness.fs.frontendStatistics.executedRequests == 0)
    }

    @Test func enforcesBoundedRequestBeforeGenericServerExecution() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let request = makeFuseRequest(
            opcode: .write,
            unique: 702,
            payload: [UInt8](repeating: 0, count: VirtioFSRequestAdmission.maximumPayloadBytes + 1)
        )

        let pending = try harness.enqueueDescriptorChain([
            .readable(request),
            .writable(FuseOutHeader.byteCount),
        ], queue: 1)
        let response = try harness.waitForFuseResponse(pending)
        #expect(try FuseProtocol.decodeOutHeader(response).error == -FuseProtocol.linuxErrno(E2BIG))
        #expect(harness.fs.frontendStatistics.rejectedRequests == 1)
        #expect(harness.fs.frontendStatistics.executedRequests == 0)
    }

    @Test func enforcesHiprioAndNormalRequestQueueOpcodeRouting() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(0)
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)

        let wrongHiprio = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .statfs, unique: 710)),
            .writable(FuseOutHeader.byteCount),
        ], queue: 0)
        #expect(try FuseProtocol.decodeOutHeader(
            harness.waitForFuseResponse(wrongHiprio)
        ).error == -FuseProtocol.linuxErrno(EPROTO))

        var interruptPayload = [UInt8]()
        interruptPayload.appendLE(UInt64(0x1234))
        let wrongInterrupt = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .interrupt, unique: 711, payload: interruptPayload)),
            .writable(FuseOutHeader.byteCount),
        ], queue: 1)
        #expect(try FuseProtocol.decodeOutHeader(
            harness.waitForFuseResponse(wrongInterrupt)
        ).error == -FuseProtocol.linuxErrno(EPROTO))

        var forgetPayload = [UInt8]()
        forgetPayload.appendLE(UInt64(1))
        let wrongForget = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .forget, unique: 712, payload: forgetPayload)),
        ], queue: 1)
        try harness.waitForUsed(wrongForget)
        #expect(try harness.usedLength(wrongForget) == 0)

        var batchPayload = [UInt8]()
        batchPayload.appendLE(UInt32(0))
        batchPayload.appendLE(UInt32(0))
        let wrongBatch = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .batchForget, unique: 713, payload: batchPayload)),
        ], queue: 1)
        try harness.waitForUsed(wrongBatch)
        #expect(try harness.usedLength(wrongBatch) == 0)

        let interruptWithoutResponse = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .interrupt, unique: 714, payload: interruptPayload)),
        ], queue: 0)
        try harness.waitForUsed(interruptWithoutResponse)
        #expect(try harness.usedLength(interruptWithoutResponse) == 0)

        let interrupt = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .interrupt, unique: 715, payload: interruptPayload)),
            .writable(FuseOutHeader.byteCount),
        ], queue: 0)
        #expect(try FuseProtocol.decodeOutHeader(
            harness.waitForFuseResponse(interrupt)
        ).error == 0)

        let forget = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .forget, unique: 716, payload: forgetPayload)),
        ], queue: 0)
        try harness.waitForUsed(forget)
        #expect(try harness.usedLength(forget) == 0)

        let batch = try harness.enqueueDescriptorChain([
            .readable(makeFuseRequest(opcode: .batchForget, unique: 717, payload: batchPayload)),
        ], queue: 0)
        try harness.waitForUsed(batch)
        #expect(try harness.usedLength(batch) == 0)

        #expect(harness.fs.frontendStatistics == VirtioFSFrontendStatistics(
            rejectedRequests: 5,
            executedRequests: 3,
            terminalQueueFaults: 0
        ))
    }

    @Test func rejectsInsufficientSuccessCapacityBeforeHostMutation() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        var payload = [UInt8]()
        payload.appendLE(UInt32(0o755))
        payload.appendLE(UInt32(0))
        payload.append(contentsOf: "must-not-exist\0".utf8)

        let response = try harness.performFuseRequest(
            makeFuseRequest(opcode: .mkdir, unique: 720, payload: payload),
            queue: 1,
            responseCapacity: FuseOutHeader.byteCount
        )
        #expect(try FuseProtocol.decodeOutHeader(response).error == -FuseProtocol.linuxErrno(EIO))
        #expect(!FileManager.default.fileExists(
            atPath: harness.rootURL.appendingPathComponent("must-not-exist").path
        ))
        #expect(harness.fs.frontendStatistics.executedRequests == 0)
    }

    @Test func oneAdmittedMutationCrossesTheGenericExecutionSeamOnce() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let executions = LockedIntCounter()
        harness.fs.requestExecutionTestHook = { header, opcode in
            guard header.unique == 721, opcode == .mkdir else { return }
            executions.increment()
        }
        defer { harness.fs.requestExecutionTestHook = nil }
        var payload = [UInt8]()
        payload.appendLE(UInt32(0o755))
        payload.appendLE(UInt32(0))
        payload.append(contentsOf: "exactly-once\0".utf8)

        let response = try harness.performFuseRequest(
            makeFuseRequest(opcode: .mkdir, unique: 721, payload: payload),
            queue: 1,
            responseCapacity: FuseOutHeader.byteCount + 128
        )
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(executions.value == 1)
        #expect(FileManager.default.fileExists(
            atPath: harness.rootURL.appendingPathComponent("exactly-once").path
        ))
        #expect(harness.fs.frontendStatistics.executedRequests == 1)
    }

    @Test func measuresEachAdmittedRequestOwnershipBoundaryAndLatency() async throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let request = makeFuseRequest(opcode: .statfs, unique: 722)

        let response = try harness.performFuseRequest(
            request,
            queue: 1,
            responseCapacity: FuseOutHeader.byteCount + 128
        )
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(await eventually {
            let statistics = harness.fs.performanceStatistics
            return statistics.completedRequests == 1
                && statistics.inFlightRequests == 0
        })

        let statistics = harness.fs.performanceStatistics
        #expect(statistics == VirtioFSPerformanceStatistics(
            requestPayloadBytes: UInt64(request.count),
            workerResponsePayloadBytes: UInt64(response.count),
            guestPublishedResponseBytes: UInt64(response.count),
            completedRequests: 1,
            failedRequests: 0,
            inFlightRequests: 0,
            peakInFlightRequests: 1,
            totalRequestLatencyNanoseconds: statistics.maximumRequestLatencyNanoseconds,
            maximumRequestLatencyNanoseconds: statistics.maximumRequestLatencyNanoseconds
        ))
    }

    @Test func burstBeyondBrokerCapacityBackpressuresAndFairlyResumesRequestQueues() async throws {
        let lifecycle = WorkerLifecycleRecorder()
        let harness = try VirtioFSNotificationHarness(
            requestQueueCount: 8,
            onWorkerLifecycle: lifecycle.record
        )
        for queue in 1...8 { try harness.configureQueue(queue) }
        harness.setDriverReady(notifications: false)

        let entered = LockedIntCounter()
        let releaseExecution = DispatchSemaphore(value: 0)
        harness.workerChannel.beforeRequestExecutionTestHook = {
            entered.increment()
            releaseExecution.wait()
        }
        defer {
            harness.workerChannel.beforeRequestExecutionTestHook = nil
            for _ in 0..<40 { releaseExecution.signal() }
        }

        var burst = [(queue: Int, request: [UInt8])]()
        burst.reserveCapacity(40)
        for queue in 1...8 {
            for offset in 0..<5 {
                burst.append((
                    queue: queue,
                    request: makeFuseRequest(
                        opcode: .statfs,
                        unique: UInt64(800 + (queue - 1) * 5 + offset)
                    )
                ))
            }
        }
        let pending = try harness.enqueueSmallFuseRequestBurst(
            burst,
            responseCapacity: FuseOutHeader.byteCount + 128
        )

        #expect(harness.fs.performanceStatistics.inFlightRequests == 32)
        #expect(harness.fs.capacityDeferredRequestQueueSnapshot == Set([7, 8]))
        #expect(await eventually(timeout: .seconds(5)) { entered.value == 32 })
        #expect(lifecycle.snapshot.isEmpty)
        #expect(await harness.broker.snapshot().state == .active)

        for _ in 0..<40 { releaseExecution.signal() }
        for queue in 1...8 {
            #expect(await eventually(timeout: .seconds(5)) {
                (try? harness.usedIndex(queue: queue)) == 5
            })
        }
        #expect(await eventually(timeout: .seconds(5)) {
            let statistics = harness.fs.performanceStatistics
            return statistics.completedRequests == 40
                && statistics.failedRequests == 0
                && statistics.inFlightRequests == 0
        })
        for request in pending {
            #expect(try harness.responseLength(request) >= UInt32(FuseOutHeader.byteCount))
        }
        #expect(harness.fs.capacityDeferredRequestQueueSnapshot.isEmpty)
        #expect(lifecycle.snapshot.isEmpty)
        #expect(await harness.broker.snapshot().state == .active)
    }

    @Test func lowerShareCeilingBackpressuresBeforePopWithoutWorkerInvalidation() async throws {
        let shareLimits = try fsShareResourceLimits(maximumInFlightRequests: 2)
        let lifecycle = WorkerLifecycleRecorder()
        let harness = try VirtioFSNotificationHarness(
            requestQueueCount: 3,
            shareResourceLimits: shareLimits,
            onWorkerLifecycle: lifecycle.record
        )
        for queue in 1...3 { try harness.configureQueue(queue) }
        harness.setDriverReady(notifications: false)

        let entered = LockedIntCounter()
        let releaseExecution = DispatchSemaphore(value: 0)
        harness.workerChannel.beforeRequestExecutionTestHook = {
            entered.increment()
            releaseExecution.wait()
        }
        defer {
            harness.workerChannel.beforeRequestExecutionTestHook = nil
            for _ in 0..<3 { releaseExecution.signal() }
        }

        let pending = try harness.enqueueSmallFuseRequestBurst(
            (1...3).map { queue in
                (
                    queue: queue,
                    request: makeFuseRequest(
                        opcode: .statfs,
                        unique: UInt64(900 + queue)
                    )
                )
            },
            responseCapacity: FuseOutHeader.byteCount + 80
        )

        #expect(harness.broker.effectiveAdmissionLimits.maximumInFlightRequests == 2)
        #expect(await eventually { entered.value == 2 })
        #expect(harness.fs.capacityDeferredRequestQueueSnapshot == Set([3]))
        #expect(harness.broker.workspaceAdmissionSnapshot.inFlightRequests == 2)
        #expect(harness.broker.workspaceAdmissionSnapshot.peakInFlightRequests == 2)
        #expect(lifecycle.snapshot.isEmpty)
        #expect(await harness.broker.snapshot().state == .active)

        releaseExecution.signal()
        #expect(await eventually { entered.value == 3 })
        #expect(harness.broker.workspaceAdmissionSnapshot.inFlightRequests == 2)
        #expect(harness.broker.workspaceAdmissionSnapshot.peakInFlightRequests == 2)

        for _ in 0..<3 { releaseExecution.signal() }
        for request in pending { try harness.waitForUsed(request) }
        #expect(await eventually {
            harness.broker.workspaceAdmissionSnapshot.inFlightRequests == 0
        })
        #expect(harness.fs.capacityDeferredRequestQueueSnapshot.isEmpty)
        #expect(lifecycle.snapshot.isEmpty)
        #expect(await harness.broker.snapshot().state == .active)
    }

    @Test func crossShareAggregateSaturationFairlyReservesReleasedWorkspaceCapacity() async throws {
        let workerLimits = try fsWorkerAdmissionLimits(
            maximumInFlightRequests: 4,
            maximumAggregateRequestBytes: 80,
            maximumAggregateResponseBytes: 192
        )
        let shareLimits = try fsShareResourceLimits(
            maximumInFlightRequests: 4,
            maximumAggregateRequestBytes: 80,
            maximumAggregateResponseBytes: 192
        )
        let generation = try DoryFSWorkerGeneration(rawValue: 77)
        let firstCapability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001"))
        )
        let secondCapability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002"))
        )
        let authority = DoryFSWorkerWorkspaceAdmissionAuthority(
            workerLimits: workerLimits,
            shareLimits: [
                firstCapability: shareLimits,
                secondCapability: shareLimits,
            ]
        )
        let firstLifecycle = WorkerLifecycleRecorder()
        let secondLifecycle = WorkerLifecycleRecorder()
        let first = try VirtioFSNotificationHarness(
            workerLimits: workerLimits,
            shareResourceLimits: shareLimits,
            generation: generation,
            capabilityID: firstCapability,
            admissionAuthority: authority,
            onWorkerLifecycle: firstLifecycle.record
        )
        let second = try VirtioFSNotificationHarness(
            workerLimits: workerLimits,
            shareResourceLimits: shareLimits,
            generation: generation,
            capabilityID: secondCapability,
            admissionAuthority: authority,
            onWorkerLifecycle: secondLifecycle.record
        )
        try first.configureQueue(1)
        try second.configureQueue(1)
        first.setDriverReady(notifications: false)
        second.setDriverReady(notifications: false)

        let entered = LockedUInt64Recorder()
        let releaseExecution = DispatchSemaphore(value: 0)
        first.workerChannel.requestExecutionCorrelationTestHook = { correlationID in
            entered.append(correlationID)
            releaseExecution.wait()
        }
        second.workerChannel.requestExecutionCorrelationTestHook = { correlationID in
            entered.append(correlationID)
            releaseExecution.wait()
        }
        defer {
            first.workerChannel.requestExecutionCorrelationTestHook = nil
            second.workerChannel.requestExecutionCorrelationTestHook = nil
            for _ in 0..<4 { releaseExecution.signal() }
        }

        let firstInitial = try first.enqueueSmallFuseRequestBurst([(
            queue: 1,
            request: makeFuseRequest(opcode: .statfs, unique: 1_001)
        )], responseCapacity: FuseOutHeader.byteCount + 80)
        let secondInitial = try second.enqueueSmallFuseRequestBurst([(
            queue: 1,
            request: makeFuseRequest(opcode: .statfs, unique: 2_001)
        )], responseCapacity: FuseOutHeader.byteCount + 80)
        #expect(await eventually { entered.snapshot.count == 2 })

        let firstDeferred = try first.enqueueSmallFuseRequestBurst([(
            queue: 1,
            request: makeFuseRequest(opcode: .statfs, unique: 1_002)
        )], responseCapacity: FuseOutHeader.byteCount + 80)
        let secondDeferred = try second.enqueueSmallFuseRequestBurst([(
            queue: 1,
            request: makeFuseRequest(opcode: .statfs, unique: 2_002)
        )], responseCapacity: FuseOutHeader.byteCount + 80)

        var workspace = first.broker.workspaceAdmissionSnapshot
        #expect(workspace.inFlightRequests == 2)
        #expect(workspace.aggregateRequestBytes == 80)
        #expect(workspace.aggregateResponseBytes == 192)
        #expect(workspace.deferredWaiters == 2)
        #expect(first.fs.capacityDeferredRequestQueueSnapshot == Set([1]))
        #expect(second.fs.capacityDeferredRequestQueueSnapshot == Set([1]))

        releaseExecution.signal()
        #expect(await eventually { entered.snapshot.contains(1_002) })
        #expect(!entered.snapshot.contains(2_002))
        workspace = first.broker.workspaceAdmissionSnapshot
        #expect(workspace.inFlightRequests == 2)
        #expect(workspace.peakInFlightRequests == 2)
        #expect(workspace.deferredWaiters == 1)

        releaseExecution.signal()
        #expect(await eventually { entered.snapshot.contains(2_002) })
        workspace = first.broker.workspaceAdmissionSnapshot
        #expect(workspace.inFlightRequests == 2)
        #expect(workspace.peakInFlightRequests == 2)
        #expect(workspace.deferredWaiters == 0)

        for _ in 0..<4 { releaseExecution.signal() }
        try first.waitForUsed(try #require(firstDeferred.last))
        try second.waitForUsed(try #require(secondDeferred.last))
        for request in firstInitial + firstDeferred {
            #expect(try first.responseLength(request) >= UInt32(FuseOutHeader.byteCount))
        }
        for request in secondInitial + secondDeferred {
            #expect(try second.responseLength(request) >= UInt32(FuseOutHeader.byteCount))
        }
        #expect(await eventually {
            first.broker.workspaceAdmissionSnapshot.inFlightRequests == 0
        })
        #expect(firstLifecycle.snapshot.isEmpty)
        #expect(secondLifecycle.snapshot.isEmpty)
        #expect(await first.broker.snapshot().state == .active)
        #expect(await second.broker.snapshot().state == .active)
    }

    @Test func workspaceInvalidationTerminatesCapacityDeferredSiblingFrontend() async throws {
        let workerLimits = try fsWorkerAdmissionLimits(
            maximumInFlightRequests: 1,
            maximumAggregateRequestBytes: FuseInHeader.byteCount,
            maximumAggregateResponseBytes: FuseOutHeader.byteCount + 80
        )
        let shareLimits = try fsShareResourceLimits(
            maximumInFlightRequests: 1,
            maximumAggregateRequestBytes: FuseInHeader.byteCount,
            maximumAggregateResponseBytes: FuseOutHeader.byteCount + 80
        )
        let generation = try DoryFSWorkerGeneration(rawValue: 78)
        let firstCapability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000011"))
        )
        let secondCapability = try DoryFSShareCapabilityID(
            rawValue: #require(UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000012"))
        )
        let authority = DoryFSWorkerWorkspaceAdmissionAuthority(
            workerLimits: workerLimits,
            shareLimits: [
                firstCapability: shareLimits,
                secondCapability: shareLimits,
            ]
        )
        let firstLifecycle = WorkerLifecycleRecorder()
        let secondLifecycle = WorkerLifecycleRecorder()
        let first = try VirtioFSNotificationHarness(
            workerLimits: workerLimits,
            shareResourceLimits: shareLimits,
            generation: generation,
            capabilityID: firstCapability,
            admissionAuthority: authority,
            onWorkerLifecycle: firstLifecycle.record
        )
        let second = try VirtioFSNotificationHarness(
            workerLimits: workerLimits,
            shareResourceLimits: shareLimits,
            generation: generation,
            capabilityID: secondCapability,
            admissionAuthority: authority,
            onWorkerLifecycle: secondLifecycle.record
        )
        try first.configureQueue(1)
        try second.configureQueue(1)
        first.setDriverReady(notifications: false)
        second.setDriverReady(notifications: false)

        let entered = DispatchSemaphore(value: 0)
        let releaseExecution = DispatchSemaphore(value: 0)
        first.workerChannel.beforeRequestExecutionTestHook = {
            entered.signal()
            releaseExecution.wait()
        }
        defer {
            first.workerChannel.beforeRequestExecutionTestHook = nil
            releaseExecution.signal()
        }

        _ = try first.enqueueSmallFuseRequestBurst([(
            queue: 1,
            request: makeFuseRequest(opcode: .statfs, unique: 3_001)
        )], responseCapacity: FuseOutHeader.byteCount + 80)
        #expect(await semaphoreSignals(entered))

        _ = try second.enqueueSmallFuseRequestBurst([(
            queue: 1,
            request: makeFuseRequest(opcode: .statfs, unique: 4_001)
        )], responseCapacity: FuseOutHeader.byteCount + 80)
        #expect(second.fs.capacityDeferredRequestQueueSnapshot == Set([1]))
        #expect(try second.usedIndex(queue: 1) == 0)

        await first.broker.invalidate()

        #expect(await eventually {
            second.fs.capacityDeferredRequestQueueSnapshot.isEmpty
                && secondLifecycle.snapshot.count == 1
        })
        guard case .failure(let diagnostic) = try #require(secondLifecycle.snapshot.first) else {
            Issue.record("expected deferred sibling admission to report terminal worker failure")
            return
        }
        #expect(diagnostic.contains("filesystem worker admission terminated"))
        #expect(try second.usedIndex(queue: 1) == 0)
        // The test channels are intentionally independent. The sibling broker therefore remains
        // active here, proving the frontend was terminated by the shared admission authority
        // rather than by a coincidental channel-invalidation callback.
        #expect(await second.broker.snapshot().state == .active)
    }

    @Test func resetOvertakesBlockedHostWorkAndRejectsItsStalePublication() async throws {
        let harness = try VirtioFSNotificationHarness(inlineRequests: false)
        try harness.write("before", to: "reset-during-write.txt")
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        let lookup = try harness.performFuseRequest(
            makeFuseRequest(
                opcode: .lookup,
                unique: 730,
                payload: Array("reset-during-write.txt\0".utf8)
            ),
            queue: 1
        )
        let nodeID = Array(lookup.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)
        var openPayload = [UInt8]()
        openPayload.appendLE(UInt32(O_RDWR))
        openPayload.appendLE(UInt32(0))
        let opened = try harness.performFuseRequest(
            makeFuseRequest(
                opcode: .open,
                unique: 731,
                nodeID: nodeID,
                payload: openPayload
            ),
            queue: 1
        )
        let handle = Array(opened.dropFirst(FuseOutHeader.byteCount)).leUInt64(at: 0)

        let hostWorkLoaded = DispatchSemaphore(value: 0)
        let releaseHostWork = DispatchSemaphore(value: 0)
        harness.workerChannel.server.fileOperationLoadedTestHook = {
            hostWorkLoaded.signal()
            releaseHostWork.wait()
        }
        defer {
            releaseHostWork.signal()
            harness.workerChannel.server.fileOperationLoadedTestHook = nil
        }
        let stale = try harness.enqueueFuseRequest(
            makeFuseWriteRequest(
                unique: 732,
                nodeID: nodeID,
                handle: handle,
                contents: Array("after!".utf8)
            ),
            queue: 1,
            responseCapacity: FuseOutHeader.byteCount + 8
        )
        #expect(await semaphoreSignals(hostWorkLoaded))

        let resetReturned = DispatchSemaphore(value: 0)
        let transport = harness.transport
        DispatchQueue.global().async {
            transport.write(offset: 0x070, value: 0, width: 4)
            resetReturned.signal()
        }
        let resetOvertookHostWork = await semaphoreSignals(
            resetReturned,
            timeout: .milliseconds(500)
        )
        guard resetOvertookHostWork else {
            releaseHostWork.signal()
            _ = await semaphoreSignals(resetReturned)
            Issue.record("device reset waited on a guest queue lease during host filesystem work")
            return
        }

        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)
        releaseHostWork.signal()
        #expect(await eventually {
            (try? harness.contents(of: "reset-during-write.txt")) == "after!"
        })
        #expect(try harness.usedIndex(queue: 1) == 0)
        #expect(try harness.responseLength(stale) == 0)

        #expect(await eventually {
            await harness.broker.snapshot().state == .invalidated
        })
        #expect(await eventually {
            let statistics = harness.fs.performanceStatistics
            return statistics.completedRequests == 2
                && statistics.failedRequests == 1
                && statistics.inFlightRequests == 0
        })
    }

    @Test func malformedVirtqueueWalkLatchesExplicitTerminalTelemetry() throws {
        let harness = try VirtioFSNotificationHarness()
        try harness.configureQueue(1)
        harness.setDriverReady(notifications: false)

        try harness.enqueueOutOfBoundsHead(queue: 1)

        #expect(try harness.usedIndex(queue: 1) == 0)
        #expect(harness.fs.frontendStatistics.terminalQueueFaults == 1)
        #expect(harness.fs.requestPublicationGateClosed)
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

private final class VirtioFSNotificationHarness: @unchecked Sendable {
    private static let base: UInt64 = 0x8000_0000
    // Queue rings, notification buffers, maximum-sized requests, and responses occupy disjoint
    // fixture regions so adversarial request sizes cannot corrupt the harness itself.
    private static let memorySize: UInt64 = 0x40_0000
    private let root: TestVirtioFSRoot
    let hostFS: HostFS
    let workerChannel: DoryFSWorkerTestChannel
    let broker: DoryFSWorkerBroker
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
        inlineRequests: Bool? = nil,
        workerLimits: DoryFSWorkerLimits = .production,
        shareResourceLimits: DoryFSShareResourceLimits = .production,
        generation: DoryFSWorkerGeneration = DoryFSWorkerTestChannel.generation,
        capabilityID: DoryFSShareCapabilityID = DoryFSWorkerTestChannel.capabilityID,
        admissionAuthority: DoryFSWorkerWorkspaceAdmissionAuthority? = nil,
        onWorkerLifecycle: @escaping @Sendable (VirtioFSWorkerLifecycleEvent) -> Void = { _ in }
    ) throws {
        root = try TestVirtioFSRoot()
        hostFS = try HostFS(rootPath: root.url.path)
        workerChannel = DoryFSWorkerTestChannel(
            hostFS: hostFS,
            executeInline: inlineRequests ?? false,
            generation: generation,
            capabilityID: capabilityID
        )
        if let admissionAuthority {
            broker = DoryFSWorkerBroker(
                shareCapabilityID: capabilityID,
                generation: generation,
                limits: workerLimits,
                shareResourceLimits: shareResourceLimits,
                admissionAuthority: admissionAuthority,
                channel: workerChannel
            )
        } else {
            broker = DoryFSWorkerBroker(
                shareCapabilityID: capabilityID,
                generation: generation,
                limits: workerLimits,
                shareResourceLimits: shareResourceLimits,
                channel: workerChannel
            )
        }
        fs = try VirtioFS(
            tag: "home",
            broker: broker,
            requestQueueCount: requestQueueCount,
            notificationBacklogLimit: notificationBacklogLimit,
            onWorkerLifecycle: onWorkerLifecycle
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
        transport.write(offset: 0x024, value: 0, width: 4)
        transport.write(
            offset: 0x020,
            value: notifications ? VirtioFS.notificationFeature : 0,
            width: 4
        )
        transport.write(offset: 0x024, value: 1, width: 4)
        transport.write(offset: 0x020, value: VirtqueueFeature.version1 >> 32, width: 4)
        transport.write(offset: 0x070, value: 0x0B, width: 4)
        transport.write(offset: 0x070, value: 0x0F, width: 4)
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
        Self.base + 0x10_0000 + UInt64(index) * UInt64(VirtioFS.notificationBufferSize)
    }

    func usedIndex(queue: Int) throws -> UInt16 {
        try memory.read(UInt16.self, at: queueLayout(queue).used + 2)
    }

    func usedLength(_ pending: PendingFuseRequest) throws -> UInt32 {
        let slot = UInt64((pending.expectedUsedIndex &- 1) % 32)
        return try memory.read(
            UInt32.self,
            at: queueLayout(pending.queue).used + 8 + slot * 8
        )
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

    func prepareCoherentCaching() async throws {
        try await prepareCoherentCachingEligibility()
        let eligibility = fs.cacheActivationEligibility
        guard eligibility.isEligible,
              fs.activateCoherentCaching() == .ineligible(eligibility),
              !fs.coherentCachingActive else {
            throw VirtioFSHarnessError.cacheActivationFailed
        }
    }

    func prepareCoherentCachingEligibility() async throws {
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
        _ = try await waitForCommittedCacheActivationEligibility()
    }

    /// A used-ring response is the guest-visible publication boundary, not the end of the host's
    /// two-phase worker acknowledgement. Cache readiness intentionally becomes true only after the
    /// broker has committed that publication. Await the exact predicate instead of assuming that
    /// observing the response also joined the asynchronous frontend task.
    func waitForCommittedCacheActivationEligibility(
        timeout: Duration = .seconds(2)
    ) async throws -> VirtioFSCacheActivationEligibility {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let eligibility = fs.cacheActivationEligibility
            if eligibility.isEligible,
               await broker.snapshot().pendingPublications == 0 {
                return eligibility
            }
            await Task.yield()
        }
        throw VirtioFSHarnessError.cacheActivationFailed
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
        let requestAddress = Self.base + 0x20_0000 + UInt64(queue) * 0x1_100
        let responseAddress = Self.base + 0x38_0000 + UInt64(queue) * 0x1_000
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

    func enqueueDescriptorChain(
        _ descriptors: [FuseDescriptorFixture],
        queue: Int,
        kick: Bool = true
    ) throws -> PendingFuseRequest {
        guard !descriptors.isEmpty, descriptors.count <= 32 else {
            throw VirtioFSHarnessError.invalidDescriptorFixture
        }
        let layout = queueLayout(queue)
        var readableAddress = Self.base + 0x20_0000 + UInt64(queue) * 0x1_100
        var writableAddress = Self.base + 0x38_0000 + UInt64(queue) * 0x1_000
        var firstWritableAddress: UInt64?
        var writableCapacity = 0

        for (index, descriptor) in descriptors.enumerated() {
            guard descriptor.length >= 0,
                  let wireLength = UInt32(exactly: descriptor.length),
                  descriptor.deviceWritable || descriptor.bytes.count == descriptor.length else {
                throw VirtioFSHarnessError.invalidDescriptorFixture
            }
            let dataAddress: UInt64
            if descriptor.deviceWritable {
                dataAddress = writableAddress
                firstWritableAddress = firstWritableAddress ?? dataAddress
                if descriptor.length > 0 {
                    try memory.write(
                        [UInt8](repeating: 0, count: descriptor.length),
                        at: dataAddress
                    )
                }
                writableAddress += UInt64(max(1, descriptor.length))
                writableCapacity += descriptor.length
            } else {
                dataAddress = readableAddress
                if !descriptor.bytes.isEmpty {
                    try memory.write(descriptor.bytes, at: dataAddress)
                }
                readableAddress += UInt64(max(1, descriptor.length))
            }

            let descriptorAddress = layout.descriptor + UInt64(index) * 16
            try memory.write(dataAddress, at: descriptorAddress)
            try memory.write(wireLength, at: descriptorAddress + 8)
            var flags: UInt16 = descriptor.deviceWritable ? 0x2 : 0
            if index + 1 < descriptors.count { flags |= 0x1 }
            try memory.write(flags, at: descriptorAddress + 12)
            try memory.write(UInt16(index + 1), at: descriptorAddress + 14)
        }

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
            responseAddress: firstWritableAddress ?? 0,
            responseCapacity: writableCapacity
        )
    }

    /// Builds several independent two-descriptor chains per request queue without kicking until the
    /// complete burst is visible. This fixture is intentionally small-payload-only: its purpose is
    /// to exercise frontend admission/backpressure, while the ordinary helper retains the separate
    /// one-MiB request/response regions used by payload-boundary tests.
    func enqueueSmallFuseRequestBurst(
        _ requests: [(queue: Int, request: [UInt8])],
        responseCapacity: Int
    ) throws -> [PendingFuseRequest] {
        guard responseCapacity > 0, responseCapacity <= 0x100 else {
            throw VirtioFSHarnessError.invalidDescriptorFixture
        }
        var pending = [PendingFuseRequest]()
        pending.reserveCapacity(requests.count)
        var queues = Set<Int>()

        for entry in requests {
            guard entry.queue > 0,
                  entry.queue < fs.queueCount,
                  !entry.request.isEmpty,
                  entry.request.count <= 0x100 else {
                throw VirtioFSHarnessError.invalidDescriptorFixture
            }
            let layout = queueLayout(entry.queue)
            let next = requestIndexLock.withLock {
                let next = (requestAvailIndices[entry.queue] ?? 0) &+ 1
                requestAvailIndices[entry.queue] = next
                return next
            }
            let ordinal = Int(next &- 1)
            guard ordinal < 16 else {
                throw VirtioFSHarnessError.invalidDescriptorFixture
            }
            let requestAddress = Self.base
                + 0x20_0000
                + UInt64(entry.queue) * 0x4000
                + UInt64(ordinal) * 0x100
            let responseAddress = Self.base
                + 0x30_0000
                + UInt64(entry.queue) * 0x4000
                + UInt64(ordinal) * 0x100
            try memory.write(entry.request, at: requestAddress)
            try memory.write(
                [UInt8](repeating: 0, count: responseCapacity),
                at: responseAddress
            )

            let readableDescriptor = UInt16(ordinal * 2)
            let writableDescriptor = readableDescriptor + 1
            let readableDescriptorAddress = layout.descriptor
                + UInt64(readableDescriptor) * 16
            try memory.write(requestAddress, at: readableDescriptorAddress)
            try memory.write(UInt32(entry.request.count), at: readableDescriptorAddress + 8)
            try memory.write(UInt16(0x1), at: readableDescriptorAddress + 12)
            try memory.write(writableDescriptor, at: readableDescriptorAddress + 14)

            let writableDescriptorAddress = layout.descriptor
                + UInt64(writableDescriptor) * 16
            try memory.write(responseAddress, at: writableDescriptorAddress)
            try memory.write(UInt32(responseCapacity), at: writableDescriptorAddress + 8)
            try memory.write(UInt16(0x2), at: writableDescriptorAddress + 12)
            try memory.write(UInt16(0), at: writableDescriptorAddress + 14)

            let slot = (next &- 1) % 32
            try memory.write(
                readableDescriptor,
                at: layout.avail + 4 + UInt64(slot) * 2
            )
            try memory.write(next, at: layout.avail + 2)
            queues.insert(entry.queue)
            pending.append(PendingFuseRequest(
                queue: entry.queue,
                expectedUsedIndex: next,
                responseAddress: responseAddress,
                responseCapacity: responseCapacity
            ))
        }

        for queue in queues.sorted() {
            fs.handleKick(queue: queue, transport: transport)
        }
        return pending
    }

    func enqueueOutOfBoundsHead(queue: Int, kick: Bool = true) throws {
        let layout = queueLayout(queue)
        let next = requestIndexLock.withLock {
            let next = (requestAvailIndices[queue] ?? 0) &+ 1
            requestAvailIndices[queue] = next
            return next
        }
        let slot = (next &- 1) % 32
        try memory.write(UInt16(32), at: layout.avail + 4 + UInt64(slot) * 2)
        try memory.write(next, at: layout.avail + 2)
        if kick {
            fs.handleKick(queue: queue, transport: transport)
        }
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

    func waitForUsed(
        _ pending: PendingFuseRequest,
        timeout: TimeInterval = 2
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try usedIndex(queue: pending.queue) == pending.expectedUsedIndex { return }
            Thread.sleep(forTimeInterval: 0.0001)
        }
        throw VirtioFSHarnessError.responseTimedOut
    }

    private func queueLayout(_ queue: Int) -> (descriptor: UInt64, avail: UInt64, used: UInt64) {
        let start = Self.base + 0x1000 + UInt64(queue) * 0x4000
        return (start, start + 0x1000, start + 0x2000)
    }
}

private enum VirtioFSHarnessError: Error {
    case invalidResponseLength(UInt32)
    case invalidDescriptorFixture
    case responseTimedOut
    case cacheActivationFailed
}

private struct FuseDescriptorFixture {
    let bytes: [UInt8]
    let length: Int
    let deviceWritable: Bool

    static func readable(_ bytes: [UInt8]) -> Self {
        Self(bytes: bytes, length: bytes.count, deviceWritable: false)
    }

    static func writable(_ byteCount: Int) -> Self {
        Self(bytes: [], length: byteCount, deviceWritable: true)
    }

    static func zeroLength(deviceWritable: Bool) -> Self {
        Self(bytes: [], length: 0, deviceWritable: deviceWritable)
    }
}

private struct PendingFuseRequest: Sendable {
    let queue: Int
    let expectedUsedIndex: UInt16
    let responseAddress: UInt64
    let responseCapacity: Int
}

private final class FuseResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8]?

    var value: [UInt8]? { lock.withLock { storage } }

    func store(_ response: [UInt8]) {
        lock.withLock { storage = response }
    }
}

private final class LockedIntCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedUInt64Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [UInt64]()

    var snapshot: [UInt64] { lock.withLock { storage } }

    func append(_ value: UInt64) {
        lock.withLock { storage.append(value) }
    }
}

private final class WorkerLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [VirtioFSWorkerLifecycleEvent]()

    var snapshot: [VirtioFSWorkerLifecycleEvent] {
        lock.withLock { events }
    }

    func record(_ event: VirtioFSWorkerLifecycleEvent) {
        lock.withLock { events.append(event) }
    }
}

private func fsWorkerAdmissionLimits(
    maximumInFlightRequests: Int,
    maximumAggregateRequestBytes: Int,
    maximumAggregateResponseBytes: Int
) throws -> DoryFSWorkerLimits {
    try DoryFSWorkerLimits(
        maximumRequestBytes: FuseInHeader.byteCount,
        maximumResponseBytes: FuseOutHeader.byteCount + 80,
        maximumFrameBytes: 512,
        maximumInFlightRequests: maximumInFlightRequests,
        maximumAggregateRequestBytes: maximumAggregateRequestBytes,
        maximumAggregateResponseBytes: maximumAggregateResponseBytes,
        maximumOperationNanoseconds: 3_000_000_000,
        maximumDrainNanoseconds: 3_000_000_000
    )
}

private func fsShareResourceLimits(
    maximumInFlightRequests: Int,
    maximumAggregateRequestBytes: Int = DoryFSShareResourceLimits.production.maximumAggregateRequestBytes,
    maximumAggregateResponseBytes: Int = DoryFSShareResourceLimits.production.maximumAggregateResponseBytes
) throws -> DoryFSShareResourceLimits {
    let production = DoryFSShareResourceLimits.production
    return try DoryFSShareResourceLimits(
        maximumInFlightRequests: maximumInFlightRequests,
        maximumAggregateRequestBytes: maximumAggregateRequestBytes,
        maximumAggregateResponseBytes: maximumAggregateResponseBytes,
        maximumLiveNonRootNodes: production.maximumLiveNonRootNodes,
        maximumFileHandles: production.maximumFileHandles,
        maximumDirectoryHandles: production.maximumDirectoryHandles,
        maximumDirectoryCursorEntries: production.maximumDirectoryCursorEntries,
        maximumDirectoryCursorNameBytes: production.maximumDirectoryCursorNameBytes,
        maximumAdvisoryLockOwners: production.maximumAdvisoryLockOwners,
        maximumPendingBlockingLocks: production.maximumPendingBlockingLocks,
        reservedFileDescriptorHeadroom: production.reservedFileDescriptorHeadroom
    )
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

private func overwriteFuseLength(_ request: inout [UInt8], with value: UInt32) {
    precondition(request.count >= MemoryLayout<UInt32>.size)
    request[0] = UInt8(truncatingIfNeeded: value)
    request[1] = UInt8(truncatingIfNeeded: value >> 8)
    request[2] = UInt8(truncatingIfNeeded: value >> 16)
    request[3] = UInt8(truncatingIfNeeded: value >> 24)
}

private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
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
