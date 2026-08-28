import Darwin
import DoryRendererWorkerContracts
import Foundation
import Metal
import Testing
@testable import DoryHV

@Suite struct DoryRendererWorkerBrokerTests {
    @Test func bootstrapTimeoutIsBoundedAndInvalidatesSilentWorker() async {
        let silent = SilentRendererWorkerBootstrapChannel()
        await expectRendererBrokerError(.deadlineExpired) {
            try await DoryRendererWorkerBroker.performBootstrap(
                channel: silent,
                exactBytes: Data(
                    repeating: 1,
                    count: DoryRendererWorkerBootstrapCodec.fixedByteCount
                ),
                timeoutNanoseconds: 1_000_000
            )
        }
        #expect(silent.invalidateCount == 1)

        let excessive = SilentRendererWorkerBootstrapChannel()
        let requested = DoryRendererWorkerBroker.maximumAdmissionDeadlineNanoseconds + 1
        await expectRendererBrokerError(.deadlineTooDistant(
            limitNanoseconds:
                DoryRendererWorkerBroker.maximumAdmissionDeadlineNanoseconds,
            actualNanoseconds: requested
        )) {
            try await DoryRendererWorkerBroker.performBootstrap(
                channel: excessive,
                exactBytes: Data(
                    repeating: 1,
                    count: DoryRendererWorkerBootstrapCodec.fixedByteCount
                ),
                timeoutNanoseconds: requested
            )
        }
        #expect(excessive.invalidateCount == 1)
    }

    @Test func partialCapabilityReceiptCannotCreateBroker() throws {
        let bootstrap = try makeRendererBootstrap()
        let partial = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: [.isolatedSignedWorker],
            capsets: []
        )
        let channel = RecordingRendererWorkerChannel()

        #expect(throws: DoryRendererWorkerBrokerError.incompleteCapabilityReceipt) {
            _ = try DoryRendererWorkerBroker(
                bootstrap: bootstrap,
                capabilityReceipt: partial,
                channel: channel
            )
        }
        #expect(channel.invalidateCount == 1)
    }

    @Test func submitCommandBytesStayDescriptorBackedAcrossAsynchronousAdmission() async throws {
        let fixture = try rendererBrokerFixture()
        let (source, byteCount) = try makeUnlinkedRegion(byteCount: 4_096, readOnly: true)
        let region = try DoryRendererSharedRegionReference(
            identity: .random(),
            descriptorIndex: 0,
            access: .readOnly,
            offset: 0,
            length: byteCount,
            declaredFileSize: byteCount
        )
        let operation = Task {
            try await fixture.broker.execute(
                operation: .submit3D,
                contextID: 7,
                sharedRegions: [region],
                descriptors: [source],
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        try source.close()

        let command = try fixture.channel.command(at: 0, limits: fixture.bootstrap.limits)
        #expect(command.operation == .submit3D)
        #expect(command.payload.isEmpty)
        #expect(command.sharedRegions == [region])
        #expect(fixture.channel.descriptorIsOpen(at: 0, descriptorIndex: 0))

        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        guard case .acknowledged = try await operation.value else {
            Issue.record("expected acknowledgement")
            return
        }
        let snapshot = await fixture.broker.snapshot()
        #expect(snapshot.submittedBatches == 1)
        #expect(snapshot.descriptorBackedCommandBytes == byteCount)
        #expect(snapshot.controlBytes < snapshot.descriptorBackedCommandBytes)
        #expect(snapshot.scanoutCopyBytes == 0)
        #expect(snapshot.inFlightCommands == 0)
    }

    @Test func maximumInFlightLimitRejectsBeforeSecondXPCBatch() async throws {
        let limits = try rendererLimits(maximumInFlight: 1)
        let fixture = try rendererBrokerFixture(limits: limits)
        let first = Task {
            try await fixture.broker.execute(
                operation: .createContext,
                contextID: 7,
                payload: try DoryRendererContextCreatePayload(
                    capsetID: 4,
                    name: "venus"
                ).encoded,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })

        await expectRendererBrokerError(.inFlightLimit(limit: 1)) {
            try await fixture.broker.execute(
                operation: .createContext,
                contextID: 8,
                payload: try DoryRendererContextCreatePayload(
                    capsetID: 4,
                    name: "second-venus"
                ).encoded,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(fixture.channel.sendCount == 1)
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        _ = try await first.value
        let snapshot = await fixture.broker.snapshot()
        #expect(snapshot.maximumObservedInFlightCommands == 1)
        #expect(snapshot.rejectedAdmissions == 1)
    }

    @Test func malformedSuccessfulReplyRevokesCompleteGeneration() async throws {
        let fixture = try rendererBrokerFixture()
        let operation = Task {
            try await fixture.broker.execute(
                operation: .createContext,
                contextID: 7,
                payload: try DoryRendererContextCreatePayload(
                    capsetID: 4,
                    name: "venus"
                ).encoded,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Data([0xff]),
                descriptors: []
            ))
        )
        await expectRendererTaskError(.replyIdentityMismatch, task: operation)
        let snapshot = await fixture.broker.snapshot()
        #expect(snapshot.state == .protocolViolation)
        #expect(snapshot.protocolViolations == 1)
        #expect(fixture.channel.invalidateCount == 1)
    }

    @Test func interruptionMakesEveryAdmittedOutcomeUnknownAndNeverReconnects() async throws {
        let fixture = try rendererBrokerFixture()
        let operation = Task {
            try await fixture.broker.execute(
                operation: .createContext,
                contextID: 7,
                payload: try DoryRendererContextCreatePayload(
                    capsetID: 4,
                    name: "venus"
                ).encoded,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.emit(.interrupted)
        await expectRendererTaskError(
            .channelFailureDuring(
                requestID: 1,
                operation: .createContext,
                failure: .interrupted
            ),
            task: operation
        )
        #expect(await fixture.broker.snapshot().state == .interrupted)

        await expectRendererBrokerError(.notActive(.interrupted)) {
            try await fixture.broker.execute(
                operation: .destroyContext,
                contextID: 7,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(fixture.channel.sendCount == 1)
    }

    @Test func backendOutcomeUnknownCarriesOnlyTypedCommandDiagnostics() async throws {
        let fixture = try rendererBrokerFixture()
        let operation = Task {
            try await fixture.broker.execute(
                operation: .destroyContext,
                contextID: 7,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        try await Task.sleep(nanoseconds: 2_000_000)
        fixture.channel.complete(
            at: 0,
            with: .failure(.serviceFailure(.outcomeUnknown))
        )

        do {
            _ = try await operation.value
            Issue.record("expected an uncertain worker outcome")
        } catch let error as DoryRendererWorkerBrokerError {
            guard case .workerOutcomeUnknown(let diagnostic) = error else {
                Issue.record("unexpected renderer broker error: \(error)")
                return
            }
            #expect(diagnostic.operation == .destroyContext)
            #expect(diagnostic.requestID == 1)
            #expect(diagnostic.stage == .workerServiceReply)
            #expect(diagnostic.status == .backendOutcomeUnknown)
            #expect(diagnostic.elapsedNanoseconds > 0)
            let rendered = String(describing: error)
            #expect(rendered.contains("destroyContext"))
            #expect(rendered.contains("requestID: 1"))
            #expect(rendered.contains("workerServiceReply"))
            #expect(rendered.contains("backendOutcomeUnknown"))
            #expect(rendered.contains("elapsedNanoseconds:"))
        }
        #expect(await fixture.broker.snapshot().state == .outcomeUnknown)
        #expect(fixture.channel.invalidateCount == 1)
    }

    @Test func brokerDeadlineCarriesTypedCommandDiagnostics() async throws {
        let fixture = try rendererBrokerFixture()
        let operation = Task {
            try await fixture.broker.execute(
                operation: .destroyContext,
                contextID: 9,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 50_000_000
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })

        do {
            _ = try await operation.value
            Issue.record("expected the broker command deadline to expire")
        } catch let error as DoryRendererWorkerBrokerError {
            guard case .workerOutcomeUnknown(let diagnostic) = error else {
                Issue.record("unexpected renderer broker error: \(error)")
                return
            }
            #expect(diagnostic.operation == .destroyContext)
            #expect(diagnostic.requestID == 1)
            #expect(diagnostic.stage == .brokerCommandDeadline)
            #expect(diagnostic.status == .deadlineExpired)
            #expect(diagnostic.elapsedNanoseconds >= 50_000_000)
            let rendered = String(describing: error)
            #expect(rendered.contains("destroyContext"))
            #expect(rendered.contains("requestID: 1"))
            #expect(rendered.contains("brokerCommandDeadline"))
            #expect(rendered.contains("deadlineExpired"))
            #expect(rendered.contains("elapsedNanoseconds:"))
        }
        #expect(await fixture.broker.snapshot().state == .outcomeUnknown)
        #expect(fixture.channel.invalidateCount == 1)
    }

    @Test func scanoutReplyTransfersExactProducerCompleteSHMWithoutCopy() async throws {
        let fixture = try rendererBrokerFixture()
        let acquire = try DoryRendererScanoutAcquirePayload(
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0
        )
        let operation = Task {
            try await fixture.broker.execute(
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 3,
                payload: acquire.encoded,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })

        let (sharedMemory, fileSize) = try makeUnlinkedRegion(
            byteCount: 4_096,
            readOnly: false
        )
        let lease = try DoryRendererScanoutLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: 42,
            resourceGeneration: 3,
            leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
            sharedRegionID: .random(),
            sharedMemoryDescriptorIndex: 0,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: false,
            width: 64,
            height: 4,
            stride: 256,
            rowAlignment: 4,
            storageOffset: 0,
            declaredFileSize: fileSize,
            leaseByteCount: 1_024,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererScanoutLeaseCodec.encode(lease),
                descriptors: [sharedMemory]
            ))
        )

        guard case .scanout(let scanout) = try await operation.value else {
            Issue.record("expected scanout lease")
            return
        }
        #expect(scanout.lease == lease)
        #expect(scanout.sharedMemoryDescriptor.fileDescriptor >= 0)
        #expect(await fixture.broker.snapshot().scanoutCopyBytes == 0)
        try scanout.sharedMemoryDescriptor.close()
    }

    @Test func scanoutReplyTransfersExactSharedMetalTextureWithoutDescriptors() async throws {
        let fixture = try rendererBrokerFixture()
        let operation = Task {
            try await fixture.broker.execute(
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 3,
                payload: try DoryRendererScanoutAcquirePayload(
                    width: 64,
                    height: 4,
                    virglFormat: 1,
                    stride: 256,
                    storageOffset: 0
                ).encoded,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 64,
            height: 4,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(device.makeSharedTexture(descriptor: descriptor))
        let handle = try #require(texture.makeSharedTextureHandle())
        let lease = try DoryRendererSharedTextureScanoutLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: 42,
            resourceGeneration: 3,
            leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: false,
            width: 64,
            height: 4,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererSharedTextureScanoutLeaseCodec.encode(lease),
                descriptors: [],
                sharedTextureHandle: handle
            ))
        )

        guard case .sharedTextureScanout(let scanout) = try await operation.value else {
            Issue.record("expected shared-texture scanout lease")
            return
        }
        #expect(scanout.lease == lease)
        let imported = try #require(device.makeSharedTexture(
            handle: scanout.sharedTextureHandle
        ))
        #expect(imported.device === device)
        #expect(imported.storageMode == .private)
        #expect(imported.width == 64)
        #expect(imported.height == 4)
        #expect(await fixture.broker.snapshot().scanoutCopyBytes == 0)
    }

    @Test func sharedTextureHandleWithLinearLeaseRevokesTheGeneration() async throws {
        let fixture = try rendererBrokerFixture()
        let operation = Task {
            try await fixture.broker.execute(
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 3,
                payload: try DoryRendererScanoutAcquirePayload(
                    width: 64,
                    height: 4,
                    virglFormat: 1,
                    stride: 256,
                    storageOffset: 0
                ).encoded,
                deadlineUptimeNanoseconds: rendererFutureDeadline()
            )
        }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 64,
            height: 4,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeSharedTexture(descriptor: descriptor))
        let handle = try #require(texture.makeSharedTextureHandle())
        let (sharedMemory, fileSize) = try makeUnlinkedRegion(
            byteCount: 4_096,
            readOnly: false
        )
        let linearLease = try DoryRendererScanoutLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: 42,
            resourceGeneration: 3,
            leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
            sharedRegionID: .random(),
            sharedMemoryDescriptorIndex: 0,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: false,
            width: 64,
            height: 4,
            stride: 256,
            rowAlignment: 4,
            storageOffset: 0,
            declaredFileSize: fileSize,
            leaseByteCount: 1_024,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererScanoutLeaseCodec.encode(linearLease),
                descriptors: [sharedMemory],
                sharedTextureHandle: handle
            ))
        )
        do {
            _ = try await operation.value
            Issue.record("expected the mismatched transport to fail")
        } catch is DoryRendererWorkerBrokerError {
            // The exact malformed-reply detail is asserted by the terminal state below.
        }
        let snapshot = await fixture.broker.snapshot()
        #expect(snapshot.state == .protocolViolation)
        #expect(snapshot.protocolViolations == 1)
        #expect(fixture.channel.invalidateCount == 1)
    }
}

@Suite struct DoryRendererWorkerVirtioCommandLaneTests {
    @Test func capsetsComeOnlyFromAuthenticatedReceiptBytes() throws {
        let fixture = try rendererBrokerFixture()
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 11
        )

        #expect(lane.capsets == [
            VirtioGPUCapset(id: 2, maxVersion: 2, data: [UInt8](repeating: 11, count: 32)),
            VirtioGPUCapset(id: 4, maxVersion: 0, data: [UInt8](repeating: 22, count: 32)),
        ])
        #expect(lane.capset(id: 2, version: 1) == lane.capsets[0])
        #expect(lane.capset(id: 4, version: 0) == lane.capsets[1])
        #expect(lane.capset(id: 4, version: 1) == nil)
    }

    @Test func resourceFollowupCommandsCarryExactAuthenticatedWorkerGeneration() async throws {
        let fixture = try rendererBrokerFixture()
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 11
        )
        let recorder = RendererLaneRecorder()
        try lane.attachResource(
            contextID: 7,
            resourceID: 29,
            resourceGeneration: 41,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let attach = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(attach.operation == .attachResource)
        #expect(attach.contextID == 7)
        #expect(attach.resourceID == 29)
        #expect(attach.resourceGeneration == 41)
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 1 })

        try lane.detachResource(
            contextID: 7,
            resourceID: 29,
            resourceGeneration: 41,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let detach = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(detach.operation == .detachResource)
        #expect(detach.resourceGeneration == 41)
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 2 })

        let backing = try makeBackingRegionSet()
        try lane.attachBacking(
            resourceID: 29,
            resourceGeneration: 41,
            regions: backing,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        // Admission owns an independent descriptor; the caller's authority may close immediately.
        closeRendererLaneRegions(backing)
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        let attachBacking = try fixture.channel.command(
            at: 2,
            limits: fixture.bootstrap.limits
        )
        #expect(attachBacking.operation == .attachBacking)
        #expect(attachBacking.resourceGeneration == 41)
        #expect(attachBacking.sharedRegions.count == 1)
        #expect(attachBacking.sharedRegions[0].access == .readWrite)
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 3 })

        try lane.detachBacking(
            resourceID: 29,
            resourceGeneration: 41,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        let detachBacking = try fixture.channel.command(
            at: 3,
            limits: fixture.bootstrap.limits
        )
        #expect(detachBacking.operation == .detachBacking)
        #expect(detachBacking.resourceGeneration == 41)
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 4 })

        let transferPayload = try DoryRendererTransfer3DPayload(
            level: 0,
            stride: 256,
            layerStride: 0,
            offset: 0,
            x: 0,
            y: 0,
            z: 0,
            width: 64,
            height: 64,
            depth: 1
        )
        try lane.transferToHost3D(
            resourceID: 29,
            resourceGeneration: 41,
            contextID: 7,
            payload: transferPayload,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 5 })
        let transferTo = try fixture.channel.command(
            at: 4,
            limits: fixture.bootstrap.limits
        )
        #expect(transferTo.operation == .transferToHost3D)
        #expect(transferTo.contextID == 7)
        #expect(try DoryRendererTransfer3DPayload.decode(
            transferTo.payload,
            operation: .transferToHost3D
        ) == transferPayload)
        fixture.channel.complete(
            at: 4,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 5 })

        try lane.transferFromHost3D(
            resourceID: 29,
            resourceGeneration: 41,
            contextID: 7,
            payload: transferPayload,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 6 })
        let transferFrom = try fixture.channel.command(
            at: 5,
            limits: fixture.bootstrap.limits
        )
        #expect(transferFrom.operation == .transferFromHost3D)
        #expect(try DoryRendererTransfer3DPayload.decode(
            transferFrom.payload,
            operation: .transferFromHost3D
        ) == transferPayload)
        fixture.channel.complete(
            at: 5,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 6 })

        try lane.unrefResource(
            resourceID: 29,
            resourceGeneration: 41,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 7 })
        let unref = try fixture.channel.command(
            at: 6,
            limits: fixture.bootstrap.limits
        )
        #expect(unref.operation == .unrefResource)
        #expect(unref.resourceGeneration == 41)
        fixture.channel.complete(
            at: 6,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 7 })
        #expect(lane.snapshot().completedResourceCommands == 5)
        #expect(lane.snapshot().completedControlCommands == 2)
        #expect(recorder.failures.isEmpty)
    }

    @Test func blobMapReturnsOnlyTheAuthenticatedSHMLeaseAndOwnedDescriptor() async throws {
        let fixture = try rendererBrokerFixture()
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 11
        )
        let recorder = RendererLaneRecorder()
        try lane.mapBlob(
            resourceID: 29,
            resourceGeneration: 41,
            deviceGeneration: 11
        ) { recorder.recordBlobMapping($0) }

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let command = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(command.operation == .mapBlob)
        #expect(command.resourceID == 29)
        #expect(command.resourceGeneration == 41)
        #expect(command.payload.isEmpty)
        #expect(command.sharedRegions.isEmpty)

        let (descriptor, fileSize) = try makeUnlinkedRegion(
            byteCount: 4_096,
            readOnly: false
        )
        let lease = try DoryRendererBlobMappingLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: 29,
            resourceGeneration: 41,
            sharedRegionID: .random(),
            descriptorIndex: 0,
            mapInfo: 3,
            declaredFileSize: fileSize,
            mappingByteCount: fileSize,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererBlobMappingLeaseCodec.encode(lease),
                descriptors: [descriptor]
            ))
        )

        #expect(await rendererEventually { recorder.blobMappings.count == 1 })
        let mapping = try #require(recorder.blobMappings.first)
        #expect(mapping.lease == lease)
        #expect(fcntl(mapping.sharedMemoryDescriptor.fileDescriptor, F_GETFD) >= 0)
        #expect(lane.snapshot().completedResourceCommands == 1)
        #expect(recorder.failures.isEmpty)
        try mapping.sharedMemoryDescriptor.close()

        try lane.unmapBlob(
            resourceID: 29,
            resourceGeneration: 41,
            deviceGeneration: 11,
            beforeWorkerUnmap: { recorder.runBlobTeardown(proceed: true) }
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        // The serialized local teardown is a mandatory predecessor of the XPC batch.
        #expect(recorder.blobTeardownCount == 1)
        let unmap = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(unmap.operation == .unmapBlob)
        #expect(unmap.resourceID == 29)
        #expect(unmap.resourceGeneration == 41)
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 1 })
        #expect(lane.snapshot().completedResourceCommands == 2)
        #expect(recorder.failures.isEmpty)
    }

    @Test func blobUnmapLocalTeardownRejectionSendsNoWorkerBatch() async throws {
        let fixture = try rendererBrokerFixture()
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 11
        )
        let recorder = RendererLaneRecorder()
        try lane.unmapBlob(
            resourceID: 29,
            resourceGeneration: 41,
            deviceGeneration: 11,
            beforeWorkerUnmap: { recorder.runBlobTeardown(proceed: false) }
        ) { recorder.recordCommand($0) }

        #expect(await rendererEventually { recorder.failures.count == 1 })
        #expect(recorder.blobTeardownCount == 1)
        #expect(recorder.failures == [.localBlobTeardownRejected])
        #expect(fixture.channel.sendCount == 0)
        #expect(lane.snapshot().completedResourceCommands == 0)
    }

    @Test func scanoutLeaseAndReleaseStayOneOrderedZeroCopyAuthority() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 11
        )
        let recorder = RendererLaneRecorder()
        try lane.acquireScanoutLease(
            resourceID: 42,
            resourceGeneration: 3,
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0,
            deviceGeneration: 11
        ) { recorder.recordScanout($0) }

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let acquireCommand = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(acquireCommand.operation == .acquireScanoutLease)
        #expect(acquireCommand.resourceID == 42)
        #expect(acquireCommand.resourceGeneration == 3)
        let acquirePayload = try DoryRendererScanoutAcquirePayload.decode(
            acquireCommand.payload
        )
        #expect(acquirePayload.width == 64)
        #expect(acquirePayload.height == 4)
        #expect(acquirePayload.virglFormat == 1)
        #expect(acquirePayload.stride == 256)
        #expect(acquirePayload.storageOffset == 0)

        let (sharedMemory, fileSize) = try makeUnlinkedRegion(
            byteCount: 4_096,
            readOnly: false
        )
        let lease = try DoryRendererScanoutLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: 42,
            resourceGeneration: 3,
            leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
            sharedRegionID: .random(),
            sharedMemoryDescriptorIndex: 0,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: false,
            width: 64,
            height: 4,
            stride: 256,
            rowAlignment: 256,
            storageOffset: 0,
            declaredFileSize: fileSize,
            leaseByteCount: 1_024,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererScanoutLeaseCodec.encode(lease),
                descriptors: [sharedMemory]
            ))
        )

        #expect(await rendererEventually { recorder.scanouts.count == 1 })
        let authority = try #require(recorder.scanouts.first)
        guard case .sharedMemory(let scanout) = authority else {
            Issue.record("expected a shared-memory scanout authority")
            return
        }
        #expect(scanout.lease == lease)
        #expect(fcntl(scanout.sharedMemoryDescriptor.fileDescriptor, F_GETFD) >= 0)
        #expect(lane.snapshot().liveScanoutLeases == 1)
        #expect(lane.snapshot().acquiredScanoutLeases == 1)
        #expect(await fixture.broker.snapshot().scanoutCopyBytes == 0)

        try lane.releaseScanoutLease(
            lease,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let releaseCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(releaseCommand.operation == .releaseScanoutLease)
        #expect(releaseCommand.resourceID == 42)
        #expect(releaseCommand.resourceGeneration == 3)
        #expect(try DoryRendererScanoutReleaseToken.decodeCommandPayload(
            releaseCommand.payload
        ) == lease.releaseToken)
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 1 })
        #expect(lane.snapshot().liveScanoutLeases == 0)
        #expect(lane.snapshot().releasedScanoutLeases == 1)
        try scanout.sharedMemoryDescriptor.close()
    }

    @Test func provenScanoutAcquireRejectionKeepsGenerationActive() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 11
        )
        let recorder = RendererLaneRecorder()
        try lane.acquireScanoutLease(
            resourceID: 42,
            resourceGeneration: 3,
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0,
            deviceGeneration: 11
        ) { recorder.recordScanout($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .failure(.serviceFailure(.commandRejected))
        )
        #expect(await rendererEventually { recorder.failures.count == 1 })
        #expect(lane.snapshot().state == .active(deviceGeneration: 11))
        #expect(lane.snapshot().liveScanoutLeases == 0)
    }

    @Test func submitAndFenceStayOrderedAndFenceDescriptorOwnsCompletion() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 11,
            maximumQueuedCommands: 4
        )
        let recorder = RendererLaneRecorder()
        lane.installCallbacks(
            fence: { generation, contextID, ringIndex, fenceID in
                recorder.recordFence(
                    generation: generation,
                    contextID: contextID,
                    ringIndex: ringIndex,
                    fenceID: fenceID
                )
            },
            runtimeFailure: { _, error in recorder.recordFailure(error) }
        )
        let regions = try makeSubmitRegionSet()
        defer { closeRendererLaneRegions(regions) }

        try lane.submit3D(
            contextID: 7,
            regions: regions,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }
        try lane.createContextFence(
            contextID: 7,
            ringIndex: 3,
            fenceID: 99,
            deviceGeneration: 11
        ) { recorder.recordCommand($0) }

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        #expect(try fixture.channel.command(at: 0, limits: fixture.bootstrap.limits).operation
            == .submit3D)
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let fenceCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(fenceCommand.operation == .createFence)
        let fencePayload = try DoryRendererFencePayload.decode(fenceCommand.payload)
        #expect(fencePayload.flags == DoryRendererFencePayload.contextTimeline)
        let (fenceDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fencePayload.encoded,
                descriptors: [fenceDescriptor]
            ))
        )
        #expect(await rendererEventually { recorder.commandSuccessCount == 2 })
        #expect(recorder.fences.isEmpty)

        close(signalDescriptor)
        #expect(await rendererEventually { recorder.fences.count == 1 })
        #expect(recorder.fences.first == RendererLaneFenceEvent(
            generation: 11,
            contextID: 7,
            ringIndex: 3,
            fenceID: 99
        ))
        let snapshot = lane.snapshot()
        #expect(snapshot.queuedCommands == 0)
        #expect(snapshot.completedSubmissions == 1)
        #expect(snapshot.armedFences == 0)
        #expect(snapshot.completedFences == 1)
        #expect(recorder.failures.isEmpty)
    }

    @Test func backpressureAndFenceReplayRejectBeforeAnotherXPCBatch() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 2))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 12,
            maximumQueuedCommands: 1
        )
        let regions = try makeSubmitRegionSet()
        defer { closeRendererLaneRegions(regions) }
        try lane.submit3D(
            contextID: 7,
            regions: regions,
            deviceGeneration: 12
        ) { _ in }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })

        do {
            try lane.submit3D(
                contextID: 7,
                regions: regions,
                deviceGeneration: 12
            ) { _ in }
            Issue.record("expected bounded command-queue rejection")
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            #expect(error == .commandQueueFull(limit: 1))
        }
        #expect(fixture.channel.sendCount == 1)
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { lane.snapshot().queuedCommands == 0 })

        let replayFixture = try rendererBrokerFixture(
            limits: rendererLimits(maximumInFlight: 4)
        )
        let replayLane = try DoryRendererWorkerVirtioCommandLane(
            broker: replayFixture.broker,
            deviceGeneration: 13,
            maximumQueuedCommands: 4
        )
        try replayLane.createContextFence(
            contextID: 7,
            ringIndex: 0,
            fenceID: 5,
            deviceGeneration: 13
        ) { _ in }
        do {
            try replayLane.createContextFence(
                contextID: 7,
                ringIndex: 0,
                fenceID: 5,
                deviceGeneration: 13
            ) { _ in }
            Issue.record("expected duplicate fence rejection")
        } catch let error as DoryRendererWorkerVirtioCommandLaneError {
            #expect(error == .duplicateFenceID(5))
        }
        #expect(await rendererEventually { replayFixture.channel.sendCount == 1 })
        #expect(replayLane.snapshot().rejectedAdmissions == 1)
    }

    @Test func workerCrashRevokesOldFenceButRestartUsesNewGeneration() async throws {
        let oldFixture = try rendererBrokerFixture(
            limits: rendererLimits(maximumInFlight: 4),
            workerGeneration: 7
        )
        let oldLane = try DoryRendererWorkerVirtioCommandLane(
            broker: oldFixture.broker,
            deviceGeneration: 20
        )
        let oldRecorder = RendererLaneRecorder()
        oldLane.installCallbacks(
            fence: { generation, contextID, ringIndex, fenceID in
                oldRecorder.recordFence(
                    generation: generation,
                    contextID: contextID,
                    ringIndex: ringIndex,
                    fenceID: fenceID
                )
            },
            runtimeFailure: { _, error in oldRecorder.recordFailure(error) }
        )
        try oldLane.createContextFence(
            contextID: 7,
            ringIndex: 1,
            fenceID: 44,
            deviceGeneration: 20
        ) { oldRecorder.recordCommand($0) }
        #expect(await rendererEventually { oldFixture.channel.sendCount == 1 })
        let oldCommand = try oldFixture.channel.command(
            at: 0,
            limits: oldFixture.bootstrap.limits
        )
        let (oldFence, oldSignal) = try makeUnsignaledFenceDescriptor()
        oldFixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: oldCommand.payload,
                descriptors: [oldFence]
            ))
        )
        #expect(await rendererEventually { oldLane.snapshot().armedFences == 1 })

        oldFixture.channel.emit(.interrupted)
        #expect(await rendererEventually {
            if case .failed(deviceGeneration: 20) = oldLane.snapshot().state { return true }
            return false
        })
        close(oldSignal)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(oldRecorder.fences.isEmpty)
        #expect(oldLane.snapshot().armedFences == 0)

        let newFixture = try rendererBrokerFixture(
            limits: rendererLimits(maximumInFlight: 4),
            workerGeneration: 8
        )
        let newLane = try DoryRendererWorkerVirtioCommandLane(
            broker: newFixture.broker,
            deviceGeneration: 21
        )
        #expect(newLane.workerGeneration.rawValue == 8)
        #expect(newLane.snapshot().state == .active(deviceGeneration: 21))
    }

    @Test func deviceResetCancelsArmedFenceWithoutPublishingCompletion() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 30
        )
        let recorder = RendererLaneRecorder()
        lane.installCallbacks(
            fence: { generation, contextID, ringIndex, fenceID in
                recorder.recordFence(
                    generation: generation,
                    contextID: contextID,
                    ringIndex: ringIndex,
                    fenceID: fenceID
                )
            },
            runtimeFailure: { _, error in recorder.recordFailure(error) }
        )
        try lane.createContextFence(
            contextID: 7,
            ringIndex: 0,
            fenceID: 70,
            deviceGeneration: 30
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let command = try fixture.channel.command(at: 0, limits: fixture.bootstrap.limits)
        let (fence, signal) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: command.payload,
                descriptors: [fence]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })

        lane.revoke(deviceGeneration: 30)
        #expect(lane.snapshot().state == .revoked(deviceGeneration: 30))
        #expect(lane.snapshot().armedFences == 0)
        close(signal)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(recorder.fences.isEmpty)
        #expect(recorder.failures.isEmpty)
    }

    @Test func workerOutcomeUnknownCancelsEveryPreviouslyArmedFence() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 31
        )
        let recorder = RendererLaneRecorder()
        lane.installCallbacks(
            fence: { generation, contextID, ringIndex, fenceID in
                recorder.recordFence(
                    generation: generation,
                    contextID: contextID,
                    ringIndex: ringIndex,
                    fenceID: fenceID
                )
            },
            runtimeFailure: { _, error in recorder.recordFailure(error) }
        )
        try lane.createContextFence(
            contextID: 7,
            ringIndex: 0,
            fenceID: 71,
            deviceGeneration: 31
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let fenceCommand = try fixture.channel.command(at: 0, limits: fixture.bootstrap.limits)
        let (fence, signal) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fenceCommand.payload,
                descriptors: [fence]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })

        let regions = try makeSubmitRegionSet()
        defer { closeRendererLaneRegions(regions) }
        try lane.submit3D(
            contextID: 7,
            regions: regions,
            deviceGeneration: 31
        ) { recorder.recordCommand($0) }
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        fixture.channel.complete(
            at: 1,
            with: .failure(.serviceFailure(.outcomeUnknown))
        )
        #expect(await rendererEventually {
            if case .failed(deviceGeneration: 31) = lane.snapshot().state { return true }
            return false
        })
        #expect(lane.snapshot().armedFences == 0)
        #expect(!recorder.failures.isEmpty)
        close(signal)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(recorder.fences.isEmpty)
    }
}

@Suite(.serialized) struct DoryRendererWorkerVirtioGPUIntegrationTests {
    @Test func initialLinuxStatusResetRebindsUnusedWorkerWithoutRevokingIt() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x5_0000_0000
        )

        let reset = queue.gpu.quiesce(reason: .deviceReset)
        #expect(reset.wait(timeout: 1) == .completed)
        #expect(lane.snapshot().state == .active(deviceGeneration: 2))
        #expect(queue.gpu.rendererLifecycleHealth == .ready(epoch: 2))
        #expect(queue.gpu.deviceFeatures == 29)
        #expect(rendererGPUUInt32(queue.gpu.configSpace, at: 12) == 2)
        #expect(fixture.channel.sendCount == 0)
        #expect(await fixture.broker.snapshot().state == .active)

        try queue.submit(rendererGPUContextCreateRequest(
            contextID: 17,
            name: "linux-after-probe-reset",
            capsetID: 4
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let create = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(create.operation == .createContext)
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
    }

    @Test func resetAfterWorkerMutationStillRevokesOneShotGeneration() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x5_8000_0000
        )
        try queue.submit(rendererGPUContextCreateRequest(
            contextID: 19,
            name: "mutated-generation",
            capsetID: 4
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        let reset = queue.gpu.quiesce(reason: .deviceReset)
        #expect(reset.wait(timeout: 1) == .completed)
        #expect(lane.snapshot().state == .revoked(deviceGeneration: 1))
    }

    @Test func authenticatedWorkerCapsetIsAdvertisedAndSubmitCompletesAsynchronously() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x6_0000_0000
        )

        #expect(queue.gpu.deviceFeatures == 29)
        #expect(rendererGPUUInt32(queue.gpu.configSpace, at: 12) == 2)

        let originalCommand: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        try queue.submit(rendererGPUSubmitRequest(
            contextID: 7,
            command: originalCommand
        ))
        #expect(try queue.usedIndex() == 0)
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })

        // The guest may rewrite its descriptor immediately after the kick. The worker must retain
        // the admitted immutable authority, never observe these replacement bytes.
        try queue.memory.write(
            [UInt8](repeating: 0xFF, count: originalCommand.count),
            at: queue.requestBuffer + 32
        )
        let command = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(command.operation == .submit3D)
        #expect(command.payload.isEmpty)
        #expect(command.sharedRegions.count == 1)
        #expect(try fixture.channel.sharedRegionBytes(
            at: 0,
            regionIndex: 0,
            limits: fixture.bootstrap.limits
        ) == originalCommand)

        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
        #expect(lane.snapshot().completedSubmissions == 1)
        let broker = await fixture.broker.snapshot()
        #expect(broker.descriptorBackedCommandBytes == UInt64(originalCommand.count))
        #expect(broker.scanoutCopyBytes == 0)
        let device = queue.gpu.statistics
        #expect(device.rendererWorkerSnapshotCount == 1)
        #expect(device.rendererWorkerSnapshotBytes == UInt64(originalCommand.count))
        #expect(device.rendererWorkerMaximumSnapshotNanoseconds
            <= device.rendererWorkerSnapshotNanoseconds)
        #expect(device.rendererWorkerCompletedSubmissions == 1)
        #expect(device.rendererWorkerScanoutCopyBytes == 0)
    }

    @Test func contextFenceDescriptorExclusivelyOwnsVirtqueueCompletion() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_0000_0000
        )
        try queue.submit(rendererGPUSubmitRequest(
            contextID: 7,
            command: [9, 8, 7, 6],
            fenceID: 99,
            ringIndex: 3,
            contextFence: true
        ))

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let fenceCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(fenceCommand.operation == .createFence)
        let fencePayload = try DoryRendererFencePayload.decode(fenceCommand.payload)
        #expect(fencePayload.flags == DoryRendererFencePayload.contextTimeline)
        #expect(fencePayload.fenceID == 99)
        let (completionDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fenceCommand.payload,
                descriptors: [completionDescriptor]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })
        #expect(try queue.usedIndex() == 0)

        close(signalDescriptor)
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
        #expect(queue.gpu.statistics.fences == 1)
        #expect(lane.snapshot().armedFences == 0)
        #expect(lane.snapshot().completedFences == 1)
    }

    @Test func contextCreationAndSubmitShareOneOrderedWorkerLane() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_8000_0000
        )
        try queue.submit(rendererGPUContextCreateRequest(
            contextID: 17,
            name: "zed",
            capsetID: 4
        ))
        #expect(try queue.usedIndex() == 0)
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let create = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(create.operation == .createContext)
        #expect(create.contextID == 17)
        #expect(try DoryRendererContextCreatePayload.decode(create.payload)
            == DoryRendererContextCreatePayload(capsetID: 4, name: "zed"))
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUSubmitRequest(
            contextID: 17,
            command: [0x10, 0x20, 0x30, 0x40]
        ))
        #expect(try queue.usedIndex() == 1)
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .submit3D)
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })
        #expect(lane.snapshot().completedControlCommands == 1)
        #expect(lane.snapshot().completedSubmissions == 1)
        #expect(queue.gpu.statistics.rendererWorkerCompletedControlCommands == 1)
    }

    @Test func workerDumbFramebufferMirrorsSurfaceLifecycleAndReusesIDAfterUnref() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_4000_0000
        )
        try queue.submit(rendererGPUContextCreateRequest(
            contextID: 19,
            name: "linux-dumb-buffer",
            capsetID: 2
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: 41,
            width: 64,
            height: 64
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let create2D = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(create2D.operation == .createResource3D)
        #expect(create2D.resourceID == 41)
        #expect(try DoryRendererResource3DCreatePayload.decode(create2D.payload)
            == DoryRendererResource3DCreatePayload(
                target: 2,
                format: 67,
                bind: (1 << 1) | (1 << 18),
                width: 64,
                height: 64,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 1
            ))
        let firstGeneration = UInt64(41).littleEndian
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: firstGeneration) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })

        let backing = [UInt8](repeating: 0x5a, count: 64 * 64 * 4)
        try queue.memory.write(backing, at: queue.backingBuffer)
        try queue.submit(rendererGPUAttachBackingRequest(
            resourceID: 41,
            entries: [(queue.backingBuffer, UInt32(backing.count))]
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        let attachBacking = try fixture.channel.command(
            at: 2,
            limits: fixture.bootstrap.limits
        )
        #expect(attachBacking.operation == .attachBacking)
        #expect(attachBacking.resourceGeneration == 41)
        #expect(try fixture.channel.sharedRegionBytes(
            at: 2,
            regionIndex: 0,
            limits: fixture.bootstrap.limits
        ) == backing)
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })

        try queue.submit(rendererGPUContextResourceRequest(
            command: 0x0202,
            contextID: 19,
            resourceID: 41
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        let contextAttach = try fixture.channel.command(
            at: 3,
            limits: fixture.bootstrap.limits
        )
        #expect(contextAttach.operation == .attachResource)
        #expect(contextAttach.resourceGeneration == 41)
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 4 })

        let fullRect = VirtioGPURect(x: 0, y: 0, width: 64, height: 64)
        try queue.submit(rendererGPUTransferToHost2DRequest(
            resourceID: 41,
            rect: fullRect
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 5 })
        let transfer = try fixture.channel.command(
            at: 4,
            limits: fixture.bootstrap.limits
        )
        #expect(transfer.operation == .transferToHost3D)
        #expect(transfer.contextID == 0)
        #expect(transfer.resourceGeneration == 41)
        #expect(try DoryRendererTransfer3DPayload.decode(
            transfer.payload,
            operation: .transferToHost3D
        ) == DoryRendererTransfer3DPayload(
            level: 0,
            stride: 0,
            layerStride: 0,
            offset: 0,
            x: 0,
            y: 0,
            z: 0,
            width: 64,
            height: 64,
            depth: 1
        ))
        fixture.channel.complete(
            at: 4,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 5 })

        let surfaceCommand = rendererVirglSurfaceCreateCommand(
            surfaceID: 73,
            resourceID: 41,
            format: 67
        )
        try queue.submit(rendererGPUSubmitRequest(
            contextID: 19,
            command: surfaceCommand
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 6 })
        let submit = try fixture.channel.command(
            at: 5,
            limits: fixture.bootstrap.limits
        )
        #expect(submit.operation == .submit3D)
        #expect(try fixture.channel.sharedRegionBytes(
            at: 5,
            regionIndex: 0,
            limits: fixture.bootstrap.limits
        ) == surfaceCommand)
        fixture.channel.complete(
            at: 5,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 6 })

        try queue.submit(rendererGPUContextResourceRequest(
            command: 0x0203,
            contextID: 19,
            resourceID: 41
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 7 })
        #expect(try fixture.channel.command(
            at: 6,
            limits: fixture.bootstrap.limits
        ).operation == .detachResource)
        fixture.channel.complete(
            at: 6,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 7 })

        try queue.submit(rendererGPUDetachBackingRequest(resourceID: 41))
        #expect(await rendererEventually { fixture.channel.sendCount == 8 })
        #expect(try fixture.channel.command(
            at: 7,
            limits: fixture.bootstrap.limits
        ).operation == .detachBacking)
        fixture.channel.complete(
            at: 7,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 8 })

        try queue.submit(rendererGPUResourceUnrefRequest(resourceID: 41))
        #expect(await rendererEventually { fixture.channel.sendCount == 9 })
        let unref = try fixture.channel.command(at: 8, limits: fixture.bootstrap.limits)
        #expect(unref.operation == .unrefResource)
        #expect(unref.resourceGeneration == 41)
        fixture.channel.complete(
            at: 8,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 9 })

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: 41,
            width: 32,
            height: 32
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 10 })
        #expect(try fixture.channel.command(
            at: 9,
            limits: fixture.bootstrap.limits
        ).operation == .createResource3D)
        let secondGeneration = UInt64(42).littleEndian
        fixture.channel.complete(
            at: 9,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: secondGeneration) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 10 })
        #expect(lane.snapshot().completedResourceCommands == 6)
    }

    @Test func workerTransfer3DDirectionsNeverFallThroughToLegacyExecutor() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_5000_0000
        )
        try queue.submit(rendererGPUContextCreateRequest(
            contextID: 21,
            name: "virgl-transfer",
            capsetID: 2
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUResourceCreate3DRequest(
            resourceID: 44,
            width: 16,
            height: 16
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let generation = UInt64(53).littleEndian
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })

        let backing = [UInt8](repeating: 0x4d, count: 16 * 16 * 4)
        try queue.memory.write(backing, at: queue.backingBuffer)
        try queue.submit(rendererGPUAttachBackingRequest(
            resourceID: 44,
            entries: [(queue.backingBuffer, UInt32(backing.count))]
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })

        let payload = try DoryRendererTransfer3DPayload(
            level: 0,
            stride: 64,
            layerStride: 0,
            offset: 0,
            x: 0,
            y: 0,
            z: 0,
            width: 16,
            height: 16,
            depth: 1
        )
        try queue.submit(rendererGPUTransfer3DRequest(
            command: 0x0205,
            resourceID: 44,
            contextID: 21,
            payload: payload
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        let toHost = try fixture.channel.command(at: 3, limits: fixture.bootstrap.limits)
        #expect(toHost.operation == .transferToHost3D)
        #expect(toHost.contextID == 21)
        #expect(toHost.resourceGeneration == 53)
        #expect(try DoryRendererTransfer3DPayload.decode(
            toHost.payload,
            operation: .transferToHost3D
        ) == payload)
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 4 })

        try queue.submit(rendererGPUTransfer3DRequest(
            command: 0x0206,
            resourceID: 44,
            contextID: 21,
            payload: payload
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 5 })
        let fromHost = try fixture.channel.command(at: 4, limits: fixture.bootstrap.limits)
        #expect(fromHost.operation == .transferFromHost3D)
        #expect(fromHost.resourceGeneration == 53)
        #expect(try DoryRendererTransfer3DPayload.decode(
            fromHost.payload,
            operation: .transferFromHost3D
        ) == payload)
        fixture.channel.complete(
            at: 4,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 5 })
    }

    @Test func workerDumbFramebufferScansOutThroughMetalWithoutContextAttachment() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let softwareFrames = RendererSoftwareScanoutRecorder()
        let metalFrames = RendererMetalScanoutRecorder()
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_6000_0000,
            scanoutCount: 1,
            onScanoutFrame: { softwareFrames.record($0) },
            onMetalScanout: { metalFrames.record($0) }
        )
        let resourceID: UInt32 = 45
        let fullRect = VirtioGPURect(x: 0, y: 0, width: 64, height: 64)

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: resourceID,
            width: 64,
            height: 64
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let create = try fixture.channel.command(at: 0, limits: fixture.bootstrap.limits)
        let createPayload = try DoryRendererResource3DCreatePayload.decode(create.payload)
        #expect(create.operation == .createResource3D)
        #expect(createPayload.bind == (1 << 1) | (1 << 18))
        #expect(createPayload.flags == 1)
        let generation = UInt64(55).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        let backing = [UInt8](repeating: 0x7c, count: 64 * 64 * 4)
        try queue.memory.write(backing, at: queue.backingBuffer)
        try queue.submit(rendererGPUAttachBackingRequest(
            resourceID: resourceID,
            entries: [(queue.backingBuffer, UInt32(backing.count))]
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .attachBacking)
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })

        try queue.submit(rendererGPUTransferToHost2DRequest(
            resourceID: resourceID,
            rect: fullRect
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        #expect(try fixture.channel.command(
            at: 2,
            limits: fixture.bootstrap.limits
        ).operation == .transferToHost3D)
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })

        try queue.submit(rendererGPUSetScanoutRequest(
            scanoutID: 0,
            resourceID: resourceID,
            rect: fullRect
        ))
        #expect(try queue.usedIndex() == 4)
        #expect(softwareFrames.values.isEmpty)
        #expect(metalFrames.values.isEmpty)

        try queue.submit(rendererGPUResourceFlushRequest(
            resourceID: resourceID,
            rect: fullRect
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        let acquire = try fixture.channel.command(at: 3, limits: fixture.bootstrap.limits)
        #expect(acquire.operation == .acquireScanoutLease)
        #expect(acquire.contextID == 0)
        #expect(acquire.resourceGeneration == 55)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 64,
            height: 64,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(device.makeSharedTexture(descriptor: descriptor))
        let handle = try #require(texture.makeSharedTextureHandle())
        let lease = try DoryRendererSharedTextureScanoutLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: resourceID,
            resourceGeneration: 55,
            leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .rgba8Unorm,
            yOriginTop: true,
            width: 64,
            height: 64,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererSharedTextureScanoutLeaseCodec.encode(lease),
                descriptors: [],
                sharedTextureHandle: handle
            ))
        )
        #expect(await rendererEventually { metalFrames.values.count == 1 })
        let update = try #require(metalFrames.takeFirst())
        #expect(update.rendererResourceGeneration == 55)
        #expect(update.presentation.yOriginTop)
        update.acceptHostSubmission()
        #expect(await rendererEventually { (try? queue.usedIndex()) == 5 })
        update.presentation.discardWithoutPresentation()
        #expect(await rendererEventually { fixture.channel.sendCount == 5 })
        #expect(try fixture.channel.command(
            at: 4,
            limits: fixture.bootstrap.limits
        ).operation == .releaseScanoutLease)
        fixture.channel.complete(
            at: 4,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { lane.snapshot().liveScanoutLeases == 0 })
        #expect(softwareFrames.values.isEmpty)
        #expect(queue.gpu.statistics.rendererWorkerScanoutCopyBytes == 0)
    }

    @Test func oneKickPreservesContextThenSubmitOrderAcrossAsyncWorkerBoundary() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_C000_0000
        )
        try queue.submitTogether([
            rendererGPUContextCreateRequest(
                contextID: 23,
                name: "zed-batch",
                capsetID: 4
            ),
            rendererGPUSubmitRequest(
                contextID: 23,
                command: [0xAA, 0xBB, 0xCC, 0xDD]
            ),
        ])

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        #expect(try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        ).operation == .createContext)
        // Draining must stop at the asynchronous context mutation. The later submit cannot cross
        // the process boundary until the exact create acknowledgement has been published.
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(fixture.channel.sendCount == 1)
        #expect(try queue.usedIndex() == 0)

        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try queue.usedIndex() == 1)
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .submit3D)

        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })
        #expect(try queue.responseType(at: 0) == 0x1100)
        #expect(try queue.responseType(at: 1) == 0x1100)
        #expect(lane.snapshot().completedControlCommands == 1)
        #expect(lane.snapshot().completedSubmissions == 1)
    }

    @Test func laterKickCannotOvertakePendingWorkerControlCommand() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_D000_0000
        )
        try queue.submitAcrossKicks([
            rendererGPUContextCreateRequest(
                contextID: 29,
                name: "zed-cross-kick",
                capsetID: 4
            ),
            rendererGPUSubmitRequest(
                contextID: 29,
                command: [0x01, 0x02, 0x03, 0x04]
            ),
        ])

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        #expect(try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        ).operation == .createContext)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(fixture.channel.sendCount == 1)
        #expect(try queue.usedIndex() == 0)

        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try queue.usedIndex() == 1)
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .submit3D)

        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })
        #expect(try queue.responseType(at: 0) == 0x1100)
        #expect(try queue.responseType(at: 1) == 0x1100)
    }

    @Test func lateSubmitCompletionCannotReleaseNewerWorkerControlCommand() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_D800_0000
        )
        let backingBytes = [UInt8](repeating: 0x6B, count: 4_096)
        try queue.memory.write(backingBytes, at: queue.backingBuffer)
        try queue.submitAcrossKicks([
            rendererGPUSubmitRequest(
                contextID: 31,
                command: [0x10, 0x20, 0x30, 0x40]
            ),
            rendererGPUCreateBlobRequest(
                resourceID: 43,
                contextID: 0,
                blobMemory: 1,
                blobFlags: 0,
                blobID: 103,
                size: UInt64(backingBytes.count),
                entries: [(queue.backingBuffer, UInt32(backingBytes.count))]
            ),
            rendererGPUContextResourceRequest(
                command: 0x0202,
                contextID: 31,
                resourceID: 43
            ),
        ])

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        #expect(try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        ).operation == .submit3D)

        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .createBlob)
        // The submit callback belongs to the older command. It must publish only that command's
        // used entry and must not release the create-blob ordering claim while its worker reply is
        // still pending; otherwise CTX_ATTACH_RESOURCE is rejected against uncommitted local state.
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(try queue.usedIndex() == 1)

        let generation = UInt64(17).littleEndian
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        let attach = try fixture.channel.command(
            at: 2,
            limits: fixture.bootstrap.limits
        )
        #expect(attach.operation == .attachResource)
        #expect(attach.resourceID == 43)
        #expect(attach.resourceGeneration == 17)
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })

        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })
        #expect(try queue.responseType(at: 0) == 0x1100)
        #expect(try queue.responseType(at: 1) == 0x1100)
        #expect(try queue.responseType(at: 2) == 0x1100)
    }

    @Test func workerVirGL3DScanoutPublishesOneNativeSharedTextureLease() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let softwareFrames = RendererSoftwareScanoutRecorder()
        let metalFrames = RendererMetalScanoutRecorder()
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_E000_0000,
            scanoutCount: 1,
            onScanoutFrame: { softwareFrames.record($0) },
            onMetalScanout: { metalFrames.record($0) }
        )
        let request = rendererGPUResourceCreate3DRequest(
            resourceID: 31,
            width: 64,
            height: 64
        )
        try queue.submit(request)

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let create3D = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(create3D.operation == .createResource3D)
        #expect(create3D.resourceID == 31)
        let resource = try DoryRendererResource3DCreatePayload.decode(create3D.payload)
        #expect(resource.format == 67)
        #expect(resource.width == 64)
        #expect(resource.height == 64)
        let generation = UInt64(77).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
        #expect(lane.snapshot().completedResourceCommands == 1)

        let fullRect = VirtioGPURect(x: 0, y: 0, width: 64, height: 64)
        try queue.submit(rendererGPUSetScanoutRequest(
            scanoutID: 0,
            resourceID: 31,
            rect: fullRect
        ))
        #expect(try queue.usedIndex() == 2)
        #expect(try queue.responseType() == 0x1100)
        #expect(softwareFrames.values.isEmpty)
        #expect(metalFrames.values.isEmpty)

        try queue.submit(rendererGPUResourceFlushRequest(
            resourceID: 31,
            rect: fullRect
        ))
        try #require(await rendererEventually { fixture.channel.sendCount == 2 })
        let acquireCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(acquireCommand.operation == .acquireScanoutLease)
        #expect(acquireCommand.resourceID == 31)
        #expect(acquireCommand.resourceGeneration == 77)
        #expect(try DoryRendererScanoutAcquirePayload.decode(acquireCommand.payload)
            == DoryRendererScanoutAcquirePayload(
                width: 64,
                height: 64,
                virglFormat: 67,
                stride: 256,
                storageOffset: 0
            ))

        let device = try #require(MTLCreateSystemDefaultDevice())
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 64,
            height: 64,
            mipmapped: false
        )
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try #require(device.makeSharedTexture(
            descriptor: textureDescriptor
        ))
        let handle = try #require(texture.makeSharedTextureHandle())
        let lease = try DoryRendererSharedTextureScanoutLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: 31,
            resourceGeneration: 77,
            leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .rgba8Unorm,
            yOriginTop: true,
            width: 64,
            height: 64,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererSharedTextureScanoutLeaseCodec.encode(lease),
                descriptors: [],
                sharedTextureHandle: handle
            ))
        )
        #expect(await rendererEventually { metalFrames.values.count == 1 })
        #expect(try queue.usedIndex() == 2)
        let update = try #require(metalFrames.takeFirst())
        #expect(update.resourceID == 31)
        #expect(update.rendererResourceGeneration == 77)
        #expect(update.presentation.transport == .sharedTexture)
        #expect(update.presentation.pixelFormat == .rgba8Unorm)
        #expect(update.sourceRect == fullRect)
        #expect(update.dirtyRect == fullRect)
        let imported = try update.presentation.withSharedTextureHandle {
            device.makeSharedTexture(handle: $0)
        }
        #expect(imported?.device === device)
        #expect(imported?.storageMode == .private)
        update.acceptHostSubmission()
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })
        #expect(try queue.responseType() == 0x1100)
        update.presentation.discardWithoutPresentation()

        try #require(await rendererEventually { fixture.channel.sendCount == 3 })
        #expect(try fixture.channel.command(
            at: 2,
            limits: fixture.bootstrap.limits
        ).operation == .releaseScanoutLease)
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { lane.snapshot().liveScanoutLeases == 0 })
        #expect(softwareFrames.values.isEmpty)
        #expect(queue.gpu.statistics.rendererWorkerScanoutCopyBytes == 0)
    }

    @Test func fencedWorkerFlushWaitsForHostAcceptanceThenGlobalFenceSignal() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let metalFrames = RendererMetalScanoutRecorder()
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_E900_0000,
            scanoutCount: 1,
            onMetalScanout: { update in
                metalFrames.record(update)
                // Deliberately reenter the completion path from the external callback.
                update.acceptHostSubmission()
            }
        )
        let resourceID: UInt32 = 49
        let resourceGeneration: UInt64 = 79
        let rect = VirtioGPURect(x: 0, y: 0, width: 32, height: 32)

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: resourceID,
            width: rect.width,
            height: rect.height
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let littleGeneration = resourceGeneration.littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: littleGeneration) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUSetScanoutRequest(
            scanoutID: 0,
            resourceID: resourceID,
            rect: rect
        ))
        #expect(try queue.usedIndex() == 2)

        let fenceID: UInt64 = 0x4455_6677_8899_AABB
        try queue.submit(rendererGPUResourceFlushRequest(
            resourceID: resourceID,
            rect: rect,
            headerFlags: 1,
            fenceID: fenceID
        ))
        try #require(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .acquireScanoutLease)
        fixture.channel.complete(
            at: 1,
            with: .success(try rendererWorkerSharedTextureReply(
                workerGeneration: fixture.bootstrap.generation,
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                width: rect.width,
                height: rect.height,
                limits: fixture.bootstrap.limits
            ))
        )

        try #require(await rendererEventually { fixture.channel.sendCount == 3 })
        #expect(metalFrames.values.count == 1)
        #expect(try queue.usedIndex() == 2)
        let fenceCommand = try fixture.channel.command(
            at: 2,
            limits: fixture.bootstrap.limits
        )
        #expect(fenceCommand.operation == .createFence)
        #expect(fenceCommand.contextID == 0)
        #expect(try DoryRendererFencePayload.decode(fenceCommand.payload).fenceID == fenceID)

        let (completionDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fenceCommand.payload,
                descriptors: [completionDescriptor]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })
        #expect(try queue.usedIndex() == 2)
        close(signalDescriptor)
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })
        #expect(try queue.responseType() == 0x1100)
        #expect(try queue.responseFlags() == 1)
        #expect(try queue.responseFenceID() == fenceID)

        let update = try #require(metalFrames.takeFirst())
        update.presentation.discardWithoutPresentation()
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        #expect(try fixture.channel.command(
            at: 3,
            limits: fixture.bootstrap.limits
        ).operation == .releaseScanoutLease)
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
    }

    @Test func synchronousMetalFlushRejectionCompletesWithoutCommandLockDeadlock() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let metalFrames = RendererMetalScanoutRecorder()
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_E980_0000,
            scanoutCount: 1,
            onMetalScanout: { update in
                metalFrames.record(update)
                // This used to reenter command completion while commandLock was still held.
                update.rejectHostSubmission()
            }
        )
        let resourceID: UInt32 = 50
        let resourceGeneration: UInt64 = 80
        let rect = VirtioGPURect(x: 0, y: 0, width: 32, height: 32)

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: resourceID,
            width: rect.width,
            height: rect.height
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let littleGeneration = resourceGeneration.littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: littleGeneration) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUSetScanoutRequest(
            scanoutID: 0,
            resourceID: resourceID,
            rect: rect
        ))
        #expect(try queue.usedIndex() == 2)

        try queue.submit(rendererGPUResourceFlushRequest(resourceID: resourceID, rect: rect))
        try #require(await rendererEventually { fixture.channel.sendCount == 2 })
        fixture.channel.complete(
            at: 1,
            with: .success(try rendererWorkerSharedTextureReply(
                workerGeneration: fixture.bootstrap.generation,
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                width: rect.width,
                height: rect.height,
                limits: fixture.bootstrap.limits
            ))
        )

        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })
        #expect(try queue.responseType() == 0x1205)
        #expect(metalFrames.values.count == 1)
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        #expect(try fixture.channel.command(
            at: 2,
            limits: fixture.bootstrap.limits
        ).operation == .releaseScanoutLease)
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        let update = try #require(metalFrames.takeFirst())
        update.presentation.discardWithoutPresentation()
        #expect(lane.snapshot().armedFences == 0)
    }

    @Test func worker3DCursorFailsClosedWithoutAuthenticatedReadback() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_E700_0000,
            scanoutCount: 1
        )
        try queue.submit(rendererGPUResourceCreate3DRequest(
            resourceID: 35,
            width: 64,
            height: 64
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let generation = UInt64(81).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submitCursor(rendererGPUUpdateCursorRequest(
            scanoutID: 0,
            resourceID: 35,
            x: 10,
            y: 20,
            hotX: 1,
            hotY: 1
        ))
        #expect(try queue.cursorUsedIndex() == 1)
        #expect(try queue.cursorResponseType() == 0x1205)
        // Cursor queue processing never blocks on or fabricates a synchronous worker readback.
        #expect(fixture.channel.sendCount == 1)
    }

    @Test func fencedLinuxResourceCreate2DWaitsForGlobalFenceAndEchoesFence() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_E800_0000
        )
        let fenceID: UInt64 = 0x1122_3344_5566_7788
        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: 37,
            width: 64,
            height: 64,
            headerFlags: 1,
            fenceID: fenceID
        ))

        #expect(try queue.usedIndex() == 0)
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let create2D = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(create2D.operation == .createResource3D)
        #expect(create2D.resourceID == 37)

        let generation = UInt64(91).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try queue.usedIndex() == 0)
        let fenceCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(fenceCommand.operation == .createFence)
        #expect(fenceCommand.contextID == 0)
        let payload = try DoryRendererFencePayload.decode(fenceCommand.payload)
        #expect(payload.flags == 0)
        #expect(payload.ringIndex == 0)
        #expect(payload.fenceID == fenceID)
        let (completionDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fenceCommand.payload,
                descriptors: [completionDescriptor]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })
        #expect(try queue.usedIndex() == 0)
        close(signalDescriptor)
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
        #expect(try queue.responseFlags() == 1)
        #expect(try queue.responseFenceID() == fenceID)
    }

    @Test func fencedTransferToHost2DWaitsForMutationThenGlobalFenceSignal() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_EA00_0000
        )

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: 39,
            width: 32,
            height: 32
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let generation = UInt64(61).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        let backing = [UInt8](repeating: 0x6d, count: 32 * 32 * 4)
        try queue.memory.write(backing, at: queue.backingBuffer)
        try queue.submit(rendererGPUAttachBackingRequest(
            resourceID: 39,
            entries: [(queue.backingBuffer, UInt32(backing.count))]
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })

        let fenceID: UInt64 = 0x8877_6655_4433_2211
        try queue.submit(rendererGPUTransferToHost2DRequest(
            resourceID: 39,
            rect: VirtioGPURect(x: 0, y: 0, width: 32, height: 32),
            headerFlags: 1,
            fenceID: fenceID
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        let transfer = try fixture.channel.command(at: 2, limits: fixture.bootstrap.limits)
        #expect(transfer.operation == .transferToHost3D)
        #expect(transfer.resourceGeneration == 61)
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        #expect(try queue.usedIndex() == 2)
        let fenceCommand = try fixture.channel.command(
            at: 3,
            limits: fixture.bootstrap.limits
        )
        #expect(fenceCommand.operation == .createFence)
        #expect(fenceCommand.contextID == 0)
        #expect(try DoryRendererFencePayload.decode(fenceCommand.payload).fenceID == fenceID)
        let (completionDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fenceCommand.payload,
                descriptors: [completionDescriptor]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })
        #expect(try queue.usedIndex() == 2)
        close(signalDescriptor)
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })
        #expect(try queue.responseType() == 0x1100)
        #expect(try queue.responseFlags() == 1)
        #expect(try queue.responseFenceID() == fenceID)
    }

    @Test func fencedAttachDetachAndUnrefUseOrderedGlobalFenceCompletion() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_EA80_0000
        )

        func completeMutationAndFence(
            mutationIndex: Int,
            fenceIndex: Int,
            fenceID: UInt64,
            expectedUsed: UInt16
        ) async throws {
            fixture.channel.complete(
                at: mutationIndex,
                with: .success(DoryRendererWorkerChannelReply(
                    payload: Data(),
                    descriptors: []
                ))
            )
            try #require(await rendererEventually {
                fixture.channel.sendCount == fenceIndex + 1
            })
            #expect(try queue.usedIndex() == expectedUsed - 1)
            let fenceCommand = try fixture.channel.command(
                at: fenceIndex,
                limits: fixture.bootstrap.limits
            )
            #expect(fenceCommand.operation == .createFence)
            #expect(fenceCommand.contextID == 0)
            #expect(try DoryRendererFencePayload.decode(fenceCommand.payload).fenceID
                == fenceID)
            let (completionDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
            fixture.channel.complete(
                at: fenceIndex,
                with: .success(DoryRendererWorkerChannelReply(
                    payload: fenceCommand.payload,
                    descriptors: [completionDescriptor]
                ))
            )
            try #require(await rendererEventually { lane.snapshot().armedFences == 1 })
            #expect(try queue.usedIndex() == expectedUsed - 1)
            close(signalDescriptor)
            try #require(await rendererEventually { (try? queue.usedIndex()) == expectedUsed })
            #expect(try queue.responseFlags() == 1)
            #expect(try queue.responseFenceID() == fenceID)
        }

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: 47,
            width: 16,
            height: 16
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let generation = UInt64(71).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        let backing = [UInt8](repeating: 0x11, count: 16 * 16 * 4)
        try queue.memory.write(backing, at: queue.backingBuffer)
        let attachFence: UInt64 = 0x101
        try queue.submit(rendererGPUAttachBackingRequest(
            resourceID: 47,
            entries: [(queue.backingBuffer, UInt32(backing.count))],
            headerFlags: 1,
            fenceID: attachFence
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .attachBacking)
        try await completeMutationAndFence(
            mutationIndex: 1,
            fenceIndex: 2,
            fenceID: attachFence,
            expectedUsed: 2
        )

        let detachFence: UInt64 = 0x102
        try queue.submit(rendererGPUDetachBackingRequest(
            resourceID: 47,
            headerFlags: 1,
            fenceID: detachFence
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        #expect(try fixture.channel.command(
            at: 3,
            limits: fixture.bootstrap.limits
        ).operation == .detachBacking)
        try await completeMutationAndFence(
            mutationIndex: 3,
            fenceIndex: 4,
            fenceID: detachFence,
            expectedUsed: 3
        )

        let unrefFence: UInt64 = 0x103
        try queue.submit(rendererGPUResourceUnrefRequest(
            resourceID: 47,
            headerFlags: 1,
            fenceID: unrefFence
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 6 })
        #expect(try fixture.channel.command(
            at: 5,
            limits: fixture.bootstrap.limits
        ).operation == .unrefResource)
        try await completeMutationAndFence(
            mutationIndex: 5,
            fenceIndex: 6,
            fenceID: unrefFence,
            expectedUsed: 4
        )
    }

    @Test func provenUnrefRejectionPreservesResourceAndScanoutBinding() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let metalFrames = RendererMetalScanoutRecorder()
        let disabled = RendererScanoutDisableRecorder()
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_EB00_0000,
            scanoutCount: 1,
            onMetalScanout: { metalFrames.record($0) },
            onScanoutDisabled: { disabled.record($0) }
        )
        let rect = VirtioGPURect(x: 0, y: 0, width: 32, height: 32)

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: 43,
            width: 32,
            height: 32
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let generation = UInt64(65).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUSetScanoutRequest(
            scanoutID: 0,
            resourceID: 43,
            rect: rect
        ))
        #expect(try queue.usedIndex() == 2)
        // Binding a worker resource retains the last completed frame until RESOURCE_FLUSH. Only
        // resource_id=0 is a real scanout disable; blanking here causes compositor flicker.
        #expect(disabled.values.isEmpty)

        try queue.submit(rendererGPUResourceUnrefRequest(resourceID: 43))
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        #expect(try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        ).operation == .unrefResource)
        fixture.channel.complete(
            at: 1,
            with: .failure(.serviceFailure(.commandRejected))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })
        #expect(try queue.responseType() == 0x1205)
        #expect(disabled.values.isEmpty)

        try queue.submit(rendererGPUResourceFlushRequest(resourceID: 43, rect: rect))
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        let acquire = try fixture.channel.command(at: 2, limits: fixture.bootstrap.limits)
        #expect(acquire.operation == .acquireScanoutLease)
        #expect(acquire.resourceGeneration == 65)
        fixture.channel.complete(
            at: 2,
            with: .failure(.serviceFailure(.commandRejected))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 4 })
        #expect(metalFrames.values.isEmpty)
    }

    @Test func workerResourceAdmissionTreatsPipeBufferWidthAsBoundedBytes() async throws {
        let maximumReferencedBytes: UInt64 = 64 * 1_024 * 1_024
        let fixture = try rendererBrokerFixture(limits: rendererLimits(
            maximumInFlight: 4,
            maximumReferencedBytes: maximumReferencedBytes
        ))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_EC00_0000
        )

        try queue.submit(rendererGPUResourceCreate3DRequest(
            resourceID: 38,
            width: 32 * 1_024 * 1_024,
            height: 1,
            target: DoryRendererResource3DCreatePayload.pipeBufferTarget,
            format: 1
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let admittedBuffer = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        let admittedPayload = try DoryRendererResource3DCreatePayload.decode(
            admittedBuffer.payload,
            maximumReferencedBytes: maximumReferencedBytes
        )
        #expect(admittedPayload.target == DoryRendererResource3DCreatePayload.pipeBufferTarget)
        #expect(admittedPayload.width == 32 * 1_024 * 1_024)
        let generation = UInt64(92).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUResourceCreate3DRequest(
            resourceID: 39,
            width: 128 * 1_024 * 1_024,
            height: 1,
            target: DoryRendererResource3DCreatePayload.pipeBufferTarget,
            format: 1
        ))
        #expect(try queue.usedIndex() == 2)
        #expect(try queue.responseType() == 0x1205)
        #expect(fixture.channel.sendCount == 1)

        try queue.submit(rendererGPUResourceCreate3DRequest(
            resourceID: 40,
            width: DoryRendererResource3DCreatePayload.maximumTextureDimension + 1,
            height: 1,
            target: 2,
            format: 67
        ))
        #expect(try queue.usedIndex() == 3)
        #expect(try queue.responseType() == 0x1205)
        #expect(fixture.channel.sendCount == 1)
    }

    @Test func oversizedWorkerOwnedCommandsNeverFallThroughToLegacyOrLocalPaths() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 8))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_F700_0000
        )
        let requests = [
            rendererGPUContextResourceRequest(
                command: 0x0202,
                contextID: 7,
                resourceID: 31
            ) + [0, 0, 0, 0],
            rendererGPUContextResourceRequest(
                command: 0x0203,
                contextID: 7,
                resourceID: 31
            ) + [0, 0, 0, 0],
            rendererGPUMapBlobRequest(resourceID: 31, offset: 0) + [0, 0, 0, 0],
            rendererGPUUnmapBlobRequest(resourceID: 31) + [0, 0, 0, 0],
            rendererGPUSubmitRequest(
                contextID: 7,
                command: [1, 2, 3, 4]
            ) + [0, 0, 0, 0],
        ]

        for (index, request) in requests.enumerated() {
            try queue.submit(request)
            #expect(try queue.usedIndex() == UInt16(index + 1))
            #expect(try queue.responseType() == 0x1205)
        }
        #expect(fixture.channel.sendCount == 0)
        #expect(lane.snapshot().completedControlCommands == 0)
        #expect(lane.snapshot().completedResourceCommands == 0)
    }

    @Test func malformedResourceCreate3DFenceHeadersNeverReachWorker() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_F800_0000
        )
        let malformedHeaders: [(flags: UInt32, fenceID: UInt64, ringIndex: UInt8)] = [
            (0, 73, 0),              // Fence id without FLAG_FENCE.
            (1, 0, 0),               // FLAG_FENCE without a fence id.
            (1 << 1, 0, 1),          // INFO_RING is not valid for this global command.
            ((1 << 0) | (1 << 1), 74, 1),
            (1 << 2, 0, 0),          // Unknown header flag.
        ]

        for (index, header) in malformedHeaders.enumerated() {
            try queue.submit(rendererGPUResourceCreate3DRequest(
                resourceID: UInt32(50 + index),
                width: 64,
                height: 64,
                headerFlags: header.flags,
                fenceID: header.fenceID,
                ringIndex: header.ringIndex
            ))
            #expect(try queue.usedIndex() == UInt16(index + 1))
            #expect(try queue.responseType() == 0x1205)
        }
        #expect(fixture.channel.sendCount == 0)
        #expect(lane.snapshot().completedResourceCommands == 0)
    }

    @Test func blobCreateUsesDescriptorBackedGuestPagesAndAuthenticatedGeneration() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x7_F000_0000
        )
        let backingBytes = [UInt8](repeating: 0xC3, count: 4_096)
        try queue.memory.write(backingBytes, at: queue.backingBuffer)
        try queue.submit(rendererGPUCreateBlobRequest(
            resourceID: 41,
            contextID: 0,
            blobMemory: 1,
            blobFlags: 0,
            blobID: 99,
            size: UInt64(backingBytes.count),
            entries: [(queue.backingBuffer, UInt32(backingBytes.count))]
        ))

        #expect(try queue.usedIndex() == 0)
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        let command = try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        )
        #expect(command.operation == .createBlob)
        #expect(command.resourceID == 41)
        #expect(command.resourceGeneration == 0)
        #expect(try DoryRendererBlobCreatePayload.decode(command.payload)
            == DoryRendererBlobCreatePayload(
                blobMemory: 1,
                blobFlags: 0,
                blobID: 99,
                size: UInt64(backingBytes.count)
            ))
        #expect(command.sharedRegions.count == 1)
        #expect(command.sharedRegions[0].access == .readWrite)
        #expect(try fixture.channel.sharedRegionBytes(
            at: 0,
            regionIndex: 0,
            limits: fixture.bootstrap.limits
        ) == backingBytes)

        let generation = UInt64(9).littleEndian
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
        #expect(lane.snapshot().completedResourceCommands == 1)
        #expect(queue.gpu.statistics.rendererWorkerCompletedResourceCommands == 1)
    }

    @Test func workerXRGBBlobScanoutPublishesAfterProducerCompleteFlush() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let softwareFrames = RendererSoftwareScanoutRecorder()
        let metalFrames = RendererMetalScanoutRecorder()
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0xA_0000_0000,
            scanoutCount: 1,
            onScanoutFrame: { softwareFrames.record($0) },
            onMetalScanout: { metalFrames.record($0) }
        )

        try queue.submit(rendererGPUContextCreateRequest(
            contextID: 23,
            name: "venus-scanout",
            capsetID: 4
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })

        try queue.submit(rendererGPUCreateBlobRequest(
            resourceID: 47,
            contextID: 23,
            blobMemory: 2,
            blobFlags: 1,
            blobID: 0,
            size: 16_384,
            entries: []
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let generation = UInt64(31).littleEndian
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: Swift.withUnsafeBytes(of: generation) { Data($0) },
                descriptors: []
            ))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })

        try queue.submit(rendererGPUContextResourceRequest(
            command: 0x0202,
            contextID: 23,
            resourceID: 47
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 3 })

        try queue.submit(rendererGPUSetScanoutBlobRequest(
            scanoutID: 0,
            resourceID: 47,
            width: 64,
            height: 64,
            format: 2,
            stride: 256,
            offset: 0
        ))
        #expect(try queue.usedIndex() == 4)
        #expect(try queue.responseType() == 0x1100)
        #expect(softwareFrames.values.isEmpty)
        #expect(metalFrames.values.isEmpty)

        try queue.submit(rendererGPUResourceFlushRequest(
            resourceID: 47,
            rect: VirtioGPURect(x: 0, y: 0, width: 64, height: 64)
        ))
        try #require(await rendererEventually { fixture.channel.sendCount == 4 })
        let acquireCommand = try fixture.channel.command(
            at: 3,
            limits: fixture.bootstrap.limits
        )
        #expect(acquireCommand.operation == .acquireScanoutLease)
        #expect(acquireCommand.resourceID == 47)
        #expect(acquireCommand.resourceGeneration == 31)
        let acquirePayload = try DoryRendererScanoutAcquirePayload.decode(acquireCommand.payload)
        #expect(acquirePayload.width == 64)
        #expect(acquirePayload.height == 64)
        #expect(acquirePayload.virglFormat == 1)
        #expect(acquirePayload.stride == 256)
        #expect(acquirePayload.storageOffset == 0)

        let (sharedMemory, fileSize) = try makeUnlinkedRegion(
            byteCount: 16_384,
            readOnly: false
        )
        let lease = try DoryRendererScanoutLease(
            workerGeneration: fixture.bootstrap.generation,
            resourceID: 47,
            resourceGeneration: 31,
            leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
            sharedRegionID: .random(),
            sharedMemoryDescriptorIndex: 0,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: false,
            width: 64,
            height: 64,
            stride: 256,
            rowAlignment: 256,
            storageOffset: 0,
            declaredFileSize: fileSize,
            leaseByteCount: 16_384,
            limits: fixture.bootstrap.limits
        )
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(
                payload: DoryRendererScanoutLeaseCodec.encode(lease),
                descriptors: [sharedMemory]
            ))
        )
        #expect(softwareFrames.values.isEmpty)
        #expect(await rendererEventually { metalFrames.values.count == 1 })
        #expect(try queue.usedIndex() == 4)
        let update = try #require(metalFrames.takeFirst())
        #expect(update.resourceID == 47)
        #expect(update.resourceGeneration == 1)
        #expect(update.rendererResourceGeneration == 31)
        #expect(update.sourceRect == VirtioGPURect(x: 0, y: 0, width: 64, height: 64))
        #expect(update.dirtyRect == VirtioGPURect(x: 0, y: 0, width: 64, height: 64))
        update.acceptHostSubmission()
        #expect(await rendererEventually { (try? queue.usedIndex()) == 5 })
        #expect(try queue.responseType() == 0x1100)
        update.presentation.discardWithoutPresentation()

        try #require(await rendererEventually { fixture.channel.sendCount == 5 })
        #expect(try fixture.channel.command(
            at: 4,
            limits: fixture.bootstrap.limits
        ).operation == .releaseScanoutLease)
        fixture.channel.complete(
            at: 4,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { lane.snapshot().liveScanoutLeases == 0 })
        #expect(softwareFrames.values.isEmpty)
        #expect(queue.gpu.statistics.rendererWorkerScanoutCopyBytes == 0)
    }

    @Test func queueResetRevokesArmedWorkerFenceWithoutGuestCompletion() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x8_0000_0000
        )
        try queue.submit(rendererGPUSubmitRequest(
            contextID: 7,
            command: [1, 1, 1, 1],
            fenceID: 101,
            ringIndex: 0,
            contextFence: true
        ))
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let fenceCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        let (completionDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fenceCommand.payload,
                descriptors: [completionDescriptor]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })

        queue.gpu.queueStateChanged(
            queue: 0,
            ready: false,
            transport: queue.transport
        )
        #expect(lane.snapshot().state == .revoked(deviceGeneration: 1))
        #expect(lane.snapshot().armedFences == 0)
        close(signalDescriptor)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(try queue.usedIndex() == 0)
        #expect(queue.gpu.statistics.queueRevokedFences == 1)
    }

    @Test func globalFenceCompletesThroughWorkerAndEchoesFullGuestUInt64ID() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x9_0000_0000
        )
        let guestFenceID = UInt64(UInt32.max) + 0x1_0000_0202
        try queue.submit(rendererGPUSubmitRequest(
            contextID: 7,
            command: [4, 3, 2, 1],
            fenceID: guestFenceID,
            ringIndex: 0,
            contextFence: false
        ))

        #expect(try queue.usedIndex() == 0)
        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let fenceCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        #expect(fenceCommand.operation == .createFence)
        #expect(fenceCommand.contextID == 7)
        let fencePayload = try DoryRendererFencePayload.decode(fenceCommand.payload)
        #expect(fencePayload.flags == 0)
        #expect(fencePayload.ringIndex == 0)
        #expect(fencePayload.fenceID == guestFenceID)

        let (completionDescriptor, signalDescriptor) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: fenceCommand.payload,
                descriptors: [completionDescriptor]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 1 })
        #expect(try queue.usedIndex() == 0)

        close(signalDescriptor)
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
        #expect(try queue.responseFlags() == 1)
        #expect(try queue.responseFenceID() == guestFenceID)
        #expect(lane.snapshot().completedSubmissions == 1)
        #expect(lane.snapshot().completedFences == 1)
    }

    @Test func globalFenceRetirementUsesAdmissionOrderAcrossUInt32Wrap() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 8))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0x9_8000_0000
        )
        let earlierGuestID = UInt64(UInt32.max) + 7
        let laterGuestID: UInt64 = 3
        try queue.submitTogether([
            rendererGPUSubmitRequest(
                contextID: 7,
                command: [1, 2, 3, 4],
                fenceID: earlierGuestID
            ),
            rendererGPUSubmitRequest(
                contextID: 7,
                command: [5, 6, 7, 8],
                fenceID: laterGuestID
            ),
        ])

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 2 })
        let earlierFenceCommand = try fixture.channel.command(
            at: 1,
            limits: fixture.bootstrap.limits
        )
        let (earlierCompletion, earlierSignal) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 1,
            with: .success(DoryRendererWorkerChannelReply(
                payload: earlierFenceCommand.payload,
                descriptors: [earlierCompletion]
            ))
        )

        #expect(await rendererEventually { fixture.channel.sendCount == 3 })
        fixture.channel.complete(
            at: 2,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { fixture.channel.sendCount == 4 })
        let laterFenceCommand = try fixture.channel.command(
            at: 3,
            limits: fixture.bootstrap.limits
        )
        let (laterCompletion, laterSignal) = try makeUnsignaledFenceDescriptor()
        fixture.channel.complete(
            at: 3,
            with: .success(DoryRendererWorkerChannelReply(
                payload: laterFenceCommand.payload,
                descriptors: [laterCompletion]
            ))
        )
        #expect(await rendererEventually { lane.snapshot().armedFences == 2 })
        #expect(try queue.usedIndex() == 0)

        // A later ctx0 retirement covers every earlier admission even though its guest id is
        // numerically smaller and crosses the UInt32 boundary.
        close(laterSignal)
        #expect(await rendererEventually { (try? queue.usedIndex()) == 2 })
        #expect(try queue.responseType(at: 0) == 0x1100)
        #expect(try queue.responseType(at: 1) == 0x1100)
        #expect(try queue.responseFenceID(at: 0) == earlierGuestID)
        #expect(try queue.responseFenceID(at: 1) == laterGuestID)

        close(earlierSignal)
        #expect(await rendererEventually { lane.snapshot().armedFences == 0 })
    }

    @Test func infoRingWithoutFenceIsAnUnfencedSubmitAndNeverCreatesFence() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 4))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0xA_0000_0000
        )
        try queue.submit(rendererGPUSubmitRequest(
            contextID: 7,
            command: [9, 10, 11, 12],
            fenceID: 0,
            ringIndex: 63,
            contextFence: true
        ))

        #expect(await rendererEventually { fixture.channel.sendCount == 1 })
        #expect(try fixture.channel.command(
            at: 0,
            limits: fixture.bootstrap.limits
        ).operation == .submit3D)
        fixture.channel.complete(
            at: 0,
            with: .success(DoryRendererWorkerChannelReply(payload: Data(), descriptors: []))
        )
        #expect(await rendererEventually { (try? queue.usedIndex()) == 1 })
        #expect(try queue.responseType() == 0x1100)
        #expect(fixture.channel.sendCount == 1)
        #expect(lane.snapshot().armedFences == 0)
    }

    @Test func malformedSubmitFencePairsRejectBeforeSubmitMutation() async throws {
        let fixture = try rendererBrokerFixture(limits: rendererLimits(maximumInFlight: 8))
        let lane = try DoryRendererWorkerVirtioCommandLane(
            broker: fixture.broker,
            deviceGeneration: 1
        )
        let queue = try RendererWorkerGPUQueueFixture(
            lane: lane,
            guestBase: 0xA_4000_0000
        )
        let ringOutOfRange = rendererGPUSubmitRequest(
            contextID: 7,
            command: [1, 2, 3, 4],
            fenceID: 0,
            ringIndex: 64,
            contextFence: true
        )
        let globalWithRing = rendererGPUSubmitRequest(
            contextID: 7,
            command: [1, 2, 3, 4],
            fenceID: 10,
            ringIndex: 1,
            contextFence: false
        )
        var fenceIDWithoutFlag = rendererGPUSubmitRequest(
            contextID: 7,
            command: [1, 2, 3, 4],
            fenceID: 11
        )
        fenceIDWithoutFlag.replaceSubrange(4..<8, with: repeatElement(UInt8(0), count: 4))
        var nonzeroHeaderPadding = rendererGPUSubmitRequest(
            contextID: 7,
            command: [1, 2, 3, 4],
            fenceID: 12
        )
        nonzeroHeaderPadding[21] = 1

        try queue.submitTogether([
            ringOutOfRange,
            globalWithRing,
            fenceIDWithoutFlag,
            nonzeroHeaderPadding,
        ])
        #expect(try queue.usedIndex() == 4)
        for index in 0..<4 {
            #expect(try queue.responseType(at: index) == 0x1205)
        }
        #expect(fixture.channel.sendCount == 0)
        #expect(lane.snapshot().completedSubmissions == 0)
    }

    @Test func fragmentedSoftwareBackingCopiesOnlyTheDirtyRowsAndCountsExactBytes() async throws {
        let frames = RendererSoftwareScanoutRecorder()
        let queue = try RendererWorkerGPUQueueFixture(
            guestBase: 0xA_8000_0000,
            scanoutCount: 1,
            onScanoutFrame: { frames.record($0) }
        )
        let resourceID: UInt32 = 61
        let pixels = Array(UInt8(0)..<UInt8(48))
        let split = 23
        try queue.memory.write(Array(pixels[..<split]), at: queue.backingBuffer)
        try queue.memory.write(Array(pixels[split...]), at: queue.backingBuffer + 0x1_000)

        try queue.submit(rendererGPUResourceCreate2DRequest(
            resourceID: resourceID,
            width: 4,
            height: 3
        ))
        try queue.submit(rendererGPUAttachBackingRequest(
            resourceID: resourceID,
            entries: [
                (queue.backingBuffer, UInt32(split)),
                (queue.backingBuffer + 0x1_000, UInt32(pixels.count - split)),
            ]
        ))
        try queue.submit(rendererGPUSetScanoutRequest(
            scanoutID: 0,
            resourceID: resourceID,
            rect: VirtioGPURect(x: 0, y: 0, width: 4, height: 3)
        ))
        let copiedBeforeDamage = queue.gpu.statistics.softwareScanoutCopiedBytes
        try queue.submit(rendererGPUResourceFlushRequest(
            resourceID: resourceID,
            rect: VirtioGPURect(x: 1, y: 1, width: 2, height: 2)
        ))

        let frame = try #require(frames.values.last)
        #expect(frame.dirtyRect == VirtioGPURect(x: 1, y: 1, width: 2, height: 2))
        #expect(Array(frame.bytes) == Array(pixels[20..<28]) + Array(pixels[36..<44]))
        #expect(queue.gpu.statistics.softwareScanoutCopiedBytes - copiedBeforeDamage == 16)
        #expect(queue.gpu.statistics.rendererWorkerScanoutCopyBytes == 0)
    }
}

private struct RendererBrokerFixture {
    let bootstrap: DoryRendererWorkerBootstrap
    let channel: RecordingRendererWorkerChannel
    let broker: DoryRendererWorkerBroker
}

private func rendererWorkerSharedTextureReply(
    workerGeneration: DoryRendererWorkerGeneration,
    resourceID: UInt32,
    resourceGeneration: UInt64,
    width: UInt32,
    height: UInt32,
    limits: DoryRendererWorkerLimits
) throws -> DoryRendererWorkerChannelReply {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: Int(width),
        height: Int(height),
        mipmapped: false
    )
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = try #require(device.makeSharedTexture(descriptor: descriptor))
    let handle = try #require(texture.makeSharedTextureHandle())
    let lease = try DoryRendererSharedTextureScanoutLease(
        workerGeneration: workerGeneration,
        resourceID: resourceID,
        resourceGeneration: resourceGeneration,
        leaseID: DoryRendererScanoutLeaseID(rawValue: UUID()),
        releaseToken: DoryRendererScanoutReleaseToken(rawValue: UUID()),
        synchronization: .managedGuestProducerCompleteFlush,
        pixelFormat: .rgba8Unorm,
        yOriginTop: true,
        width: width,
        height: height,
        limits: limits
    )
    return DoryRendererWorkerChannelReply(
        payload: DoryRendererSharedTextureScanoutLeaseCodec.encode(lease),
        descriptors: [],
        sharedTextureHandle: handle
    )
}

private final class RendererSoftwareScanoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [VirtioGPUScanoutFrame]()

    var values: [VirtioGPUScanoutFrame] {
        lock.withLock { recorded }
    }

    func record(_ frame: VirtioGPUScanoutFrame) {
        lock.withLock { recorded.append(frame) }
    }
}

private final class RendererMetalScanoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [VirtioGPUMetalScanoutUpdate]()

    var values: [VirtioGPUMetalScanoutUpdate] {
        lock.withLock { recorded }
    }

    func record(_ frame: VirtioGPUMetalScanoutUpdate) {
        lock.withLock { recorded.append(frame) }
    }

    func takeFirst() -> VirtioGPUMetalScanoutUpdate? {
        lock.withLock {
            guard !recorded.isEmpty else { return nil }
            return recorded.removeFirst()
        }
    }
}

private final class RendererScanoutDisableRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [UInt32]()

    var values: [UInt32] {
        lock.withLock { recorded }
    }

    func record(_ scanoutID: UInt32) {
        lock.withLock { recorded.append(scanoutID) }
    }
}

private final class RendererWorkerGPUQueueFixture: @unchecked Sendable {
    let memory: GuestMemory
    let gpu: VirtioGPU
    let transport: VirtioMMIOTransport
    let requestBuffer: UInt64
    let backingBuffer: UInt64

    private let descriptorTable: UInt64
    private let availableRing: UInt64
    private let usedRing: UInt64
    private let responseBuffer: UInt64
    private let cursorDescriptorTable: UInt64
    private let cursorAvailableRing: UInt64
    private let cursorUsedRing: UInt64
    private let cursorRequestBuffer: UInt64
    private let cursorResponseBuffer: UInt64
    private var availableIndex: UInt16 = 0
    private var cursorAvailableIndex: UInt16 = 0

    init(
        lane: DoryRendererWorkerVirtioCommandLane? = nil,
        guestBase: UInt64,
        scanoutCount: UInt32 = 0,
        fenceTimeoutNanoseconds: UInt64 = 10_000_000_000,
        onScanoutFrame: (@Sendable (VirtioGPUScanoutFrame) -> Void)? = nil,
        onMetalScanout: (@Sendable (VirtioGPUMetalScanoutUpdate) -> Void)? = nil,
        onScanoutDisabled: (@Sendable (UInt32) -> Void)? = nil
    ) throws {
        descriptorTable = guestBase + 0x1_000
        availableRing = guestBase + 0x4_000
        usedRing = guestBase + 0x8_000
        requestBuffer = guestBase + 0x10_000
        responseBuffer = guestBase + 0x18_000
        backingBuffer = guestBase + 0x40_000
        cursorDescriptorTable = guestBase + 0x2_000
        cursorAvailableRing = guestBase + 0x5_000
        cursorUsedRing = guestBase + 0x9_000
        cursorRequestBuffer = guestBase + 0x30_000
        cursorResponseBuffer = guestBase + 0x38_000
        memory = try GuestMemory(guestBase: guestBase, size: 32 * HostPage.size)
        gpu = VirtioGPU(
            hostMemoryBase: guestBase + 0x1_0000_0000,
            scanoutCount: scanoutCount,
            rendererWorkerCandidate: lane,
            fenceTimeoutNanoseconds: fenceTimeoutNanoseconds,
            onScanoutFrame: onScanoutFrame,
            onMetalScanout: onMetalScanout,
            onScanoutDisabled: onScanoutDisabled
        )
        transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: gpu,
            memory: memory
        ) {}
        transport.queues[0].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        )
        transport.queues[0].setReady(true)
        transport.queues[1].configure(
            size: 8,
            descriptorTable: cursorDescriptorTable,
            availRing: cursorAvailableRing,
            usedRing: cursorUsedRing
        )
        transport.queues[1].setReady(true)
    }

    func submit(_ request: [UInt8]) throws {
        try writeDescriptor(
            index: 0,
            address: requestBuffer,
            length: UInt32(request.count),
            flags: 0x1,
            next: 1
        )
        try writeDescriptor(
            index: 1,
            address: responseBuffer,
            length: 512,
            flags: 0x2,
            next: 0
        )
        try memory.write(request, at: requestBuffer)
        try memory.write([UInt8](repeating: 0, count: 512), at: responseBuffer)
        try memory.write(UInt16(0), at: availableRing)
        let slot = UInt64(availableIndex % 8)
        try memory.write(UInt16(0), at: availableRing + 4 + slot * 2)
        availableIndex &+= 1
        try memory.write(availableIndex, at: availableRing + 2)
        gpu.handleKick(queue: 0, transport: transport)
    }

    /// Publishes multiple independent chains before one kick. This models Linux batching a context
    /// mutation and its first submit into one available-ring update, without reusing descriptor or
    /// response storage while either chain is owned by the device.
    func submitTogether(_ requests: [[UInt8]]) throws {
        guard !requests.isEmpty, requests.count <= 4, availableIndex == 0 else {
            throw VMError.invalidConfiguration("invalid renderer-worker batch fixture")
        }
        try memory.write(UInt16(0), at: availableRing)
        for (index, request) in requests.enumerated() {
            let head = UInt64(index * 2)
            let requestAddress = requestBuffer + UInt64(index) * 0x1_000
            let responseAddress = responseBuffer + UInt64(index) * 0x1_000
            try writeDescriptor(
                index: head,
                address: requestAddress,
                length: UInt32(request.count),
                flags: 0x1,
                next: UInt16(head + 1)
            )
            try writeDescriptor(
                index: head + 1,
                address: responseAddress,
                length: 512,
                flags: 0x2,
                next: 0
            )
            try memory.write(request, at: requestAddress)
            try memory.write([UInt8](repeating: 0, count: 512), at: responseAddress)
            try memory.write(UInt16(head), at: availableRing + 4 + UInt64(index) * 2)
        }
        availableIndex = UInt16(requests.count)
        try memory.write(availableIndex, at: availableRing + 2)
        gpu.handleKick(queue: 0, transport: transport)
    }

    /// Publishes each later chain only after the preceding kick has returned. This exercises the
    /// cross-kick ordering boundary used by an SMP Linux guest without reusing device-owned storage.
    func submitAcrossKicks(_ requests: [[UInt8]]) throws {
        guard (2...4).contains(requests.count), availableIndex == 0 else {
            throw VMError.invalidConfiguration("invalid cross-kick renderer-worker fixture")
        }
        try memory.write(UInt16(0), at: availableRing)
        for (index, request) in requests.enumerated() {
            let head = UInt64(index * 2)
            let requestAddress = requestBuffer + UInt64(index) * 0x1_000
            let responseAddress = responseBuffer + UInt64(index) * 0x1_000
            try writeDescriptor(
                index: head,
                address: requestAddress,
                length: UInt32(request.count),
                flags: 0x1,
                next: UInt16(head + 1)
            )
            try writeDescriptor(
                index: head + 1,
                address: responseAddress,
                length: 512,
                flags: 0x2,
                next: 0
            )
            try memory.write(request, at: requestAddress)
            try memory.write([UInt8](repeating: 0, count: 512), at: responseAddress)
            try memory.write(UInt16(head), at: availableRing + 4 + UInt64(index) * 2)
        }

        for publishedCount in 1...requests.count {
            availableIndex = UInt16(publishedCount)
            try memory.write(availableIndex, at: availableRing + 2)
            gpu.handleKick(queue: 0, transport: transport)
        }
    }

    func usedIndex() throws -> UInt16 {
        try memory.read(UInt16.self, at: usedRing + 2)
    }

    func submitCursor(_ request: [UInt8]) throws {
        try writeDescriptor(
            table: cursorDescriptorTable,
            index: 0,
            address: cursorRequestBuffer,
            length: UInt32(request.count),
            flags: 0x1,
            next: 1
        )
        try writeDescriptor(
            table: cursorDescriptorTable,
            index: 1,
            address: cursorResponseBuffer,
            length: 64,
            flags: 0x2,
            next: 0
        )
        try memory.write(request, at: cursorRequestBuffer)
        try memory.write([UInt8](repeating: 0, count: 64), at: cursorResponseBuffer)
        try memory.write(UInt16(0), at: cursorAvailableRing)
        let slot = UInt64(cursorAvailableIndex % 8)
        try memory.write(UInt16(0), at: cursorAvailableRing + 4 + slot * 2)
        cursorAvailableIndex &+= 1
        try memory.write(cursorAvailableIndex, at: cursorAvailableRing + 2)
        gpu.handleKick(queue: 1, transport: transport)
    }

    func cursorUsedIndex() throws -> UInt16 {
        try memory.read(UInt16.self, at: cursorUsedRing + 2)
    }

    func cursorResponseType() throws -> UInt32 {
        try memory.read(UInt32.self, at: cursorResponseBuffer)
    }

    func responseType() throws -> UInt32 {
        try memory.read(UInt32.self, at: responseBuffer)
    }

    func responseFlags() throws -> UInt32 {
        try memory.read(UInt32.self, at: responseBuffer + 4)
    }

    func responseFenceID() throws -> UInt64 {
        try memory.read(UInt64.self, at: responseBuffer + 8)
    }

    func responseFenceID(at index: Int) throws -> UInt64 {
        guard index >= 0, index < 4 else {
            throw VMError.invalidConfiguration("invalid renderer-worker response index")
        }
        return try memory.read(
            UInt64.self,
            at: responseBuffer + UInt64(index) * 0x1_000 + 8
        )
    }

    func responseType(at index: Int) throws -> UInt32 {
        guard index >= 0, index < 4 else {
            throw VMError.invalidConfiguration("invalid renderer-worker response index")
        }
        return try memory.read(
            UInt32.self,
            at: responseBuffer + UInt64(index) * 0x1_000
        )
    }

    private func writeDescriptor(
        index: UInt64,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16
    ) throws {
        try writeDescriptor(
            table: descriptorTable,
            index: index,
            address: address,
            length: length,
            flags: flags,
            next: next
        )
    }

    private func writeDescriptor(
        table: UInt64,
        index: UInt64,
        address: UInt64,
        length: UInt32,
        flags: UInt16,
        next: UInt16
    ) throws {
        let descriptor = table + index * 16
        try memory.write(address, at: descriptor)
        try memory.write(length, at: descriptor + 8)
        try memory.write(flags, at: descriptor + 12)
        try memory.write(next, at: descriptor + 14)
    }
}

private func rendererGPUSubmitRequest(
    contextID: UInt32,
    command: [UInt8],
    fenceID: UInt64 = 0,
    ringIndex: UInt8 = 0,
    contextFence: Bool = false
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0207))
    var flags: UInt32 = fenceID == 0 ? 0 : 1
    if contextFence { flags |= 1 << 1 }
    request.appendLE(flags)
    request.appendLE(fenceID)
    request.appendLE(contextID)
    request.append(ringIndex)
    request.append(contentsOf: [0, 0, 0])
    request.appendLE(UInt32(command.count))
    request.appendLE(UInt32(0))
    request.append(contentsOf: command)
    return request
}

private func rendererGPUContextCreateRequest(
    contextID: UInt32,
    name: String,
    capsetID: UInt32
) -> [UInt8] {
    let nameBytes = Array(name.utf8.prefix(64))
    var request = [UInt8]()
    request.appendLE(UInt32(0x0200))
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(contextID)
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(UInt32(nameBytes.count))
    request.appendLE(capsetID)
    request.append(contentsOf: nameBytes)
    request.append(contentsOf: repeatElement(UInt8(0), count: 64 - nameBytes.count))
    return request
}

private func rendererGPUResourceCreate3DRequest(
    resourceID: UInt32,
    width: UInt32,
    height: UInt32,
    target: UInt32 = 2,
    format: UInt32 = 67,
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0,
    ringIndex: UInt8 = 0
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0204))
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(UInt32(0))
    request.append(ringIndex)
    request.append(contentsOf: [0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(target)
    request.appendLE(format)
    request.appendLE(UInt32(1 << 1))
    request.appendLE(width)
    request.appendLE(height)
    request.appendLE(UInt32(1))
    request.appendLE(UInt32(1))
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUResourceCreate2DRequest(
    resourceID: UInt32,
    width: UInt32,
    height: UInt32,
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0,
    ringIndex: UInt8 = 0
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0101))
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(UInt32(0))
    request.append(ringIndex)
    request.append(contentsOf: [0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(UInt32(67))
    request.appendLE(width)
    request.appendLE(height)
    return request
}

private func rendererGPUSetScanoutRequest(
    scanoutID: UInt32,
    resourceID: UInt32,
    rect: VirtioGPURect
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0103))
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(rect.x)
    request.appendLE(rect.y)
    request.appendLE(rect.width)
    request.appendLE(rect.height)
    request.appendLE(scanoutID)
    request.appendLE(resourceID)
    return request
}

private func rendererGPUUpdateCursorRequest(
    scanoutID: UInt32,
    resourceID: UInt32,
    x: UInt32,
    y: UInt32,
    hotX: UInt32,
    hotY: UInt32
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0300))
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(scanoutID)
    request.appendLE(x)
    request.appendLE(y)
    request.appendLE(UInt32(0))
    request.appendLE(resourceID)
    request.appendLE(hotX)
    request.appendLE(hotY)
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUSetScanoutBlobRequest(
    scanoutID: UInt32,
    resourceID: UInt32,
    width: UInt32,
    height: UInt32,
    format: UInt32,
    stride: UInt32,
    offset: UInt32
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x010D))
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    request.appendLE(width)
    request.appendLE(height)
    request.appendLE(scanoutID)
    request.appendLE(resourceID)
    request.appendLE(width)
    request.appendLE(height)
    request.appendLE(format)
    request.appendLE(UInt32(0))
    request.appendLE(stride)
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    request.appendLE(offset)
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUResourceFlushRequest(
    resourceID: UInt32,
    rect: VirtioGPURect,
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0104))
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(rect.x)
    request.appendLE(rect.y)
    request.appendLE(rect.width)
    request.appendLE(rect.height)
    request.appendLE(resourceID)
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUContextResourceRequest(
    command: UInt32,
    contextID: UInt32,
    resourceID: UInt32
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(command)
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(contextID)
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUAttachBackingRequest(
    resourceID: UInt32,
    entries: [(address: UInt64, length: UInt32)],
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0106))
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(UInt32(entries.count))
    for entry in entries {
        request.appendLE(entry.address)
        request.appendLE(entry.length)
        request.appendLE(UInt32(0))
    }
    return request
}

private func rendererGPUDetachBackingRequest(
    resourceID: UInt32,
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0107))
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUResourceUnrefRequest(
    resourceID: UInt32,
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0102))
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUMapBlobRequest(
    resourceID: UInt32,
    offset: UInt64
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0208))
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(UInt32(0))
    request.appendLE(offset)
    return request
}

private func rendererGPUUnmapBlobRequest(resourceID: UInt32) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0209))
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUTransferToHost2DRequest(
    resourceID: UInt32,
    rect: VirtioGPURect,
    offset: UInt64 = 0,
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x0105))
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(UInt32(0))
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(rect.x)
    request.appendLE(rect.y)
    request.appendLE(rect.width)
    request.appendLE(rect.height)
    request.appendLE(offset)
    request.appendLE(resourceID)
    request.appendLE(UInt32(0))
    return request
}

private func rendererGPUTransfer3DRequest(
    command: UInt32,
    resourceID: UInt32,
    contextID: UInt32,
    payload: DoryRendererTransfer3DPayload,
    headerFlags: UInt32 = 0,
    fenceID: UInt64 = 0
) -> [UInt8] {
    precondition(command == 0x0205 || command == 0x0206)
    var request = [UInt8]()
    request.appendLE(command)
    request.appendLE(headerFlags)
    request.appendLE(fenceID)
    request.appendLE(contextID)
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(payload.x)
    request.appendLE(payload.y)
    request.appendLE(payload.z)
    request.appendLE(payload.width)
    request.appendLE(payload.height)
    request.appendLE(payload.depth)
    request.appendLE(payload.offset)
    request.appendLE(resourceID)
    request.appendLE(payload.level)
    request.appendLE(payload.stride)
    request.appendLE(payload.layerStride)
    return request
}

private func rendererVirglSurfaceCreateCommand(
    surfaceID: UInt32,
    resourceID: UInt32,
    format: UInt32
) -> [UInt8] {
    let dwords: [UInt32] = [
        (5 << 16) | (8 << 8) | 1,
        surfaceID,
        resourceID,
        format,
        0,
        0,
    ]
    var bytes = [UInt8]()
    bytes.reserveCapacity(dwords.count * MemoryLayout<UInt32>.stride)
    for dword in dwords { bytes.appendLE(dword) }
    return bytes
}

private func rendererGPUCreateBlobRequest(
    resourceID: UInt32,
    contextID: UInt32,
    blobMemory: UInt32,
    blobFlags: UInt32,
    blobID: UInt64,
    size: UInt64,
    entries: [(address: UInt64, length: UInt32)]
) -> [UInt8] {
    var request = [UInt8]()
    request.appendLE(UInt32(0x010C))
    request.appendLE(UInt32(0))
    request.appendLE(UInt64(0))
    request.appendLE(contextID)
    request.append(contentsOf: [0, 0, 0, 0])
    request.appendLE(resourceID)
    request.appendLE(blobMemory)
    request.appendLE(blobFlags)
    request.appendLE(UInt32(entries.count))
    request.appendLE(blobID)
    request.appendLE(size)
    for entry in entries {
        request.appendLE(entry.address)
        request.appendLE(entry.length)
        request.appendLE(UInt32(0))
    }
    return request
}

private func rendererGPUUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset])
        | UInt32(bytes[offset + 1]) << 8
        | UInt32(bytes[offset + 2]) << 16
        | UInt32(bytes[offset + 3]) << 24
}

private func rendererBrokerFixture(
    limits: DoryRendererWorkerLimits = .production,
    workerGeneration: UInt64 = 7
) throws -> RendererBrokerFixture {
    let bootstrap = try makeRendererBootstrap(
        limits: limits,
        workerGeneration: workerGeneration
    )
    let receipt = try makeRendererReceipt(bootstrap: bootstrap)
    let channel = RecordingRendererWorkerChannel()
    return try RendererBrokerFixture(
        bootstrap: bootstrap,
        channel: channel,
        broker: DoryRendererWorkerBroker(
            bootstrap: bootstrap,
            capabilityReceipt: receipt,
            channel: channel
        )
    )
}

private func makeRendererBootstrap(
    limits: DoryRendererWorkerLimits = .production,
    workerGeneration: UInt64 = 7
) throws -> DoryRendererWorkerBootstrap {
    try DoryRendererWorkerBootstrap(
        workspaceID: DoryRendererWorkspaceID(
            rawValue: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        ),
        generation: DoryRendererWorkerGeneration(rawValue: workerGeneration),
        sourceTuple: .productionCandidate,
        producerFenceContract: .managedLinux612106PrepareFBV1,
        requestedCapabilities: .productionAcceleration,
        artifacts: DoryRendererArtifactManifest(
            candidateInventory: rendererDigest(1),
            managedGuestKernel: rendererDigest(2),
            guestMesa: rendererDigest(3),
            rendererWorkerExecutable: rendererDigest(4),
            rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                bytes: Data(repeating: 5, count: DoryCodeDirectoryHash.byteCount)
            )
        ),
        limits: limits
    )
}

private func makeRendererReceipt(
    bootstrap: DoryRendererWorkerBootstrap
) throws -> DoryRendererCapabilityReceipt {
    try DoryRendererCapabilityReceipt(
        accepting: bootstrap,
        features: .productionAcceleration,
        capsets: [
            DoryRendererCapsetAttestation(
                id: 2,
                maximumVersion: 2,
                data: Data(repeating: 11, count: 32)
            ),
            DoryRendererCapsetAttestation(
                id: 4,
                maximumVersion: 0,
                data: Data(repeating: 22, count: 32)
            ),
        ]
    )
}

private func rendererLimits(
    maximumInFlight: Int,
    maximumReferencedBytes: UInt64 = DoryRendererWorkerLimits.production.maximumReferencedBytes
) throws -> DoryRendererWorkerLimits {
    try DoryRendererWorkerLimits(
        maximumCommandBytes: DoryRendererWorkerLimits.production.maximumCommandBytes,
        maximumSharedRegions: DoryRendererWorkerLimits.production.maximumSharedRegions,
        maximumReferencedBytes: maximumReferencedBytes,
        maximumInFlightCommands: maximumInFlight,
        maximumLiveScanoutLeases:
            DoryRendererWorkerLimits.production.maximumLiveScanoutLeases,
        maximumScanoutBytes: DoryRendererWorkerLimits.production.maximumScanoutBytes
    )
}

private func rendererDigest(_ byte: UInt8) throws -> DoryRendererArtifactDigest {
    try DoryRendererArtifactDigest(bytes: Data(repeating: byte, count: 32))
}

private func rendererFutureDeadline() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
}

private func rendererEventually(
    attempts: Int = 200,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private func expectRendererBrokerError<Success>(
    _ expected: DoryRendererWorkerBrokerError,
    operation: () async throws -> Success
) async {
    do {
        _ = try await operation()
        Issue.record("expected renderer broker error \(expected)")
    } catch let error as DoryRendererWorkerBrokerError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected renderer broker error: \(error)")
    }
}

private func expectRendererTaskError<Success>(
    _ expected: DoryRendererWorkerBrokerError,
    task: Task<Success, any Error>
) async {
    do {
        _ = try await task.value
        Issue.record("expected renderer task error \(expected)")
    } catch let error as DoryRendererWorkerBrokerError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected renderer task error: \(error)")
    }
}

private func makeUnlinkedRegion(
    byteCount: UInt64,
    readOnly: Bool
) throws -> (FileHandle, UInt64) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("dory-renderer-broker-\(UUID().uuidString)").path
    let writable = open(path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
    guard writable >= 0,
          byteCount <= UInt64(off_t.max),
          ftruncate(writable, off_t(byteCount)) == 0 else {
        if writable >= 0 { close(writable) }
        unlink(path)
        throw POSIXError(.EIO)
    }
    let selected: Int32
    if readOnly {
        selected = open(path, O_RDONLY)
        guard selected >= 0 else {
            close(writable)
            unlink(path)
            throw POSIXError(.EIO)
        }
    } else {
        selected = writable
    }
    guard unlink(path) == 0 else {
        if readOnly { close(selected) }
        close(writable)
        throw POSIXError(.EIO)
    }
    if readOnly { close(writable) }
    return (FileHandle(fileDescriptor: selected, closeOnDealloc: true), byteCount)
}

private func makeSignaledFenceDescriptor() throws -> FileHandle {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
    close(descriptors[1])
    return FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
}

private func makeUnsignaledFenceDescriptor() throws -> (FileHandle, Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
    for descriptor in descriptors {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            close(descriptors[0])
            close(descriptors[1])
            throw POSIXError(.EMFILE)
        }
    }
    return (
        FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
        descriptors[1]
    )
}

private func makeSubmitRegionSet() throws -> DoryRendererWorkerSharedRegionSet {
    let (descriptor, byteCount) = try makeUnlinkedRegion(byteCount: 4_096, readOnly: true)
    return DoryRendererWorkerSharedRegionSet(
        references: [try DoryRendererSharedRegionReference(
            identity: .random(),
            descriptorIndex: 0,
            access: .readOnly,
            offset: 0,
            length: byteCount,
            declaredFileSize: byteCount
        )],
        descriptors: [descriptor]
    )
}

private func makeBackingRegionSet() throws -> DoryRendererWorkerSharedRegionSet {
    let (descriptor, byteCount) = try makeUnlinkedRegion(byteCount: 8_192, readOnly: false)
    return DoryRendererWorkerSharedRegionSet(
        references: [try DoryRendererSharedRegionReference(
            identity: .random(),
            descriptorIndex: 0,
            access: .readWrite,
            offset: 0,
            length: byteCount,
            declaredFileSize: byteCount
        )],
        descriptors: [descriptor]
    )
}

private func closeRendererLaneRegions(_ regions: DoryRendererWorkerSharedRegionSet) {
    for descriptor in regions.descriptors { try? descriptor.close() }
}

private struct RendererLaneFenceEvent: Equatable {
    let generation: UInt64
    let contextID: UInt32
    let ringIndex: UInt32
    let fenceID: UInt64
}

private final class RendererLaneRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commandSuccesses = 0
    private var recordedBlobMappings = [DoryRendererWorkerBlobMapping]()
    private var blobTeardowns = 0
    private var recordedScanouts = [DoryRendererWorkerScanoutAuthority]()
    private var unknownScanoutOutcomes = 0
    private var recordedFences = [RendererLaneFenceEvent]()
    private var recordedFailures = [DoryRendererWorkerVirtioCommandLaneError]()

    var commandSuccessCount: Int { lock.withLock { commandSuccesses } }
    var blobMappings: [DoryRendererWorkerBlobMapping] {
        lock.withLock { recordedBlobMappings }
    }
    var blobTeardownCount: Int { lock.withLock { blobTeardowns } }
    var scanouts: [DoryRendererWorkerScanoutAuthority] {
        lock.withLock { recordedScanouts }
    }
    var unknownScanoutOutcomeCount: Int { lock.withLock { unknownScanoutOutcomes } }
    var fences: [RendererLaneFenceEvent] { lock.withLock { recordedFences } }
    var failures: [DoryRendererWorkerVirtioCommandLaneError] {
        lock.withLock { recordedFailures }
    }

    func recordCommand(
        _ result: Result<Void, DoryRendererWorkerVirtioCommandLaneError>
    ) {
        lock.withLock {
            switch result {
            case .success:
                commandSuccesses += 1
            case .failure(let error):
                recordedFailures.append(error)
            }
        }
    }

    func recordBlobMapping(
        _ result: Result<
            DoryRendererWorkerBlobMapping,
            DoryRendererWorkerVirtioCommandLaneError
        >
    ) {
        lock.withLock {
            switch result {
            case .success(let mapping):
                recordedBlobMappings.append(mapping)
            case .failure(let error):
                recordedFailures.append(error)
            }
        }
    }

    func runBlobTeardown(proceed: Bool) -> Bool {
        lock.withLock { blobTeardowns += 1 }
        return proceed
    }

    func recordScanout(_ disposition: DoryRendererWorkerScanoutDisposition) {
        lock.withLock {
            switch disposition {
            case .acquired(let scanout):
                recordedScanouts.append(scanout)
            case .provenRejected(let error):
                recordedFailures.append(error)
            case .outcomeUnknown(let error):
                unknownScanoutOutcomes += 1
                recordedFailures.append(error)
            }
        }
    }

    func recordFence(
        generation: UInt64,
        contextID: UInt32,
        ringIndex: UInt32,
        fenceID: UInt64
    ) {
        lock.withLock {
            recordedFences.append(RendererLaneFenceEvent(
                generation: generation,
                contextID: contextID,
                ringIndex: ringIndex,
                fenceID: fenceID
            ))
        }
    }

    func recordFailure(_ error: DoryRendererWorkerVirtioCommandLaneError) {
        lock.withLock { recordedFailures.append(error) }
    }
}

private final class RecordingRendererWorkerChannel:
    DoryRendererWorkerChannel,
    @unchecked Sendable
{
    private struct PendingExchange {
        let frame: Data
        let descriptors: [FileHandle]
        let completion: @Sendable (
            Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>
        ) -> Void
    }

    private let lock = NSLock()
    private var lifecycleHandler: (@Sendable (DoryRendererWorkerChannelEvent) -> Void)?
    private var exchanges = [PendingExchange]()
    private var invalidations = 0

    func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryRendererWorkerChannelEvent) -> Void
    ) {
        lock.withLock { lifecycleHandler = handler }
    }

    func bootstrap(
        exactBytes _: Data,
        completion: @escaping @Sendable (
            Result<Data, DoryRendererWorkerChannelFailure>
        ) -> Void
    ) {
        completion(.failure(.unavailable))
    }

    func exchange(
        frame: Data,
        descriptors: [FileHandle],
        completion: @escaping @Sendable (
            Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>
        ) -> Void
    ) {
        lock.withLock {
            exchanges.append(PendingExchange(
                frame: frame,
                descriptors: descriptors,
                completion: completion
            ))
        }
    }

    func invalidate() {
        lock.withLock { invalidations += 1 }
    }

    var sendCount: Int { lock.withLock { exchanges.count } }
    var invalidateCount: Int { lock.withLock { invalidations } }

    func emit(_ event: DoryRendererWorkerChannelEvent) {
        let handler = lock.withLock { lifecycleHandler }
        handler?(event)
    }

    func command(
        at index: Int,
        limits: DoryRendererWorkerLimits
    ) throws -> DoryRendererWorkerCommand {
        let frame = lock.withLock { exchanges[index].frame }
        return try DoryRendererWorkerCommandCodec.decode(frame, limits: limits)
    }

    func descriptorIsOpen(at index: Int, descriptorIndex: Int) -> Bool {
        let descriptor = lock.withLock { exchanges[index].descriptors[descriptorIndex] }
        return fcntl(descriptor.fileDescriptor, F_GETFD) >= 0
    }

    func sharedRegionBytes(
        at index: Int,
        regionIndex: Int,
        limits: DoryRendererWorkerLimits
    ) throws -> [UInt8] {
        let exchange = lock.withLock { exchanges[index] }
        let command = try DoryRendererWorkerCommandCodec.decode(
            exchange.frame,
            limits: limits
        )
        let region = command.sharedRegions[regionIndex]
        let pageSize = UInt64(getpagesize())
        let mappingOffset = region.offset - region.offset % pageSize
        let delta = region.offset - mappingOffset
        let (mappingLength, overflow) = delta.addingReportingOverflow(region.length)
        guard !overflow,
              region.length <= UInt64(Int.max),
              mappingLength <= UInt64(Int.max),
              mappingOffset <= UInt64(off_t.max) else {
            throw POSIXError(.EOVERFLOW)
        }
        let mapped = mmap(
            nil,
            Int(mappingLength),
            PROT_READ,
            MAP_SHARED,
            exchange.descriptors[Int(region.descriptorIndex)].fileDescriptor,
            off_t(mappingOffset)
        )
        guard mapped != MAP_FAILED, let mapped else { throw POSIXError(.EIO) }
        defer { munmap(mapped, Int(mappingLength)) }
        return Array(UnsafeRawBufferPointer(
            start: mapped.advanced(by: Int(delta)),
            count: Int(region.length)
        ))
    }

    func complete(
        at index: Int,
        with result: Result<
            DoryRendererWorkerChannelReply,
            DoryRendererWorkerChannelFailure
        >
    ) {
        let completion = lock.withLock { exchanges[index].completion }
        completion(result)
    }
}

private final class SilentRendererWorkerBootstrapChannel:
    DoryRendererWorkerChannel,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var invalidations = 0

    var invalidateCount: Int { lock.withLock { invalidations } }

    func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryRendererWorkerChannelEvent) -> Void
    ) {}

    func bootstrap(
        exactBytes: Data,
        completion: @escaping @Sendable (
            Result<Data, DoryRendererWorkerChannelFailure>
        ) -> Void
    ) {}

    func exchange(
        frame: Data,
        descriptors: [FileHandle],
        completion: @escaping @Sendable (
            Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>
        ) -> Void
    ) {
        completion(.failure(.unavailable))
    }

    func invalidate() {
        lock.withLock { invalidations += 1 }
    }
}
