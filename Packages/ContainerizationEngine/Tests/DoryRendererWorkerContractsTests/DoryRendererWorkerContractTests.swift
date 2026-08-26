import DoryRendererWorkerContracts
import DoryRendererWorkerMetalTransport
import Foundation
import Metal
import Testing

@Suite struct DoryRendererWorkerContractTests {
    @Test func sharedMemoryPolicyAcceptsOnlyPrivateDarwinSHMOrRegularFiles() {
        #expect(DoryRendererSharedMemoryDescriptorPolicy.accepts(mode: 0o600))
        #expect(DoryRendererSharedMemoryDescriptorPolicy.accepts(mode: S_IFREG | 0o600))
        #expect(!DoryRendererSharedMemoryDescriptorPolicy.accepts(mode: 0o644))
        #expect(!DoryRendererSharedMemoryDescriptorPolicy.accepts(mode: S_IFIFO | 0o600))
    }

    @Test func bootstrapV3IsCanonicalAndPinsTheStaticDualRendererTuple() throws {
        #expect(
            DoryRendererSourceTuple.virglrendererRevision
                == "65cc14eb896f121ffc5130ce04815a923a03c41d"
        )
        #expect(
            DoryRendererSourceTuple.guestMesaRevision
                == "79bc850d884a1307356ff61c017e58901b90c7e2"
        )
        #expect(
            DoryRendererSourceTuple.moltenVKRevision
                == "ef1c5461774f5fbd224ddcfd91fd2c0ea23f0384"
        )
        #expect(DoryRendererSourceTuple.productionCandidate.rawValue == 3)
        let bootstrap = try makeBootstrap()
        let encoded = DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        #expect(DoryRendererWorkerBootstrapCodec.fixedByteCount == 228)
        #expect(encoded.count == DoryRendererWorkerBootstrapCodec.fixedByteCount)
        #expect(Data(encoded[0..<4]) == Data("DRB3".utf8))
        #expect(Data(encoded[172..<192])
            == bootstrap.artifacts.rendererWorkerCodeDirectoryHash.bytes)
        #expect(try DoryRendererWorkerBootstrapCodec.decode(encoded) == bootstrap)

        var incomplete = encoded
        writeUInt32(1 << 10, to: &incomplete, at: 12)
        #expect(throws: DoryRendererWorkerContractError.unknownFlags(1 << 10)) {
            _ = try DoryRendererWorkerBootstrapCodec.decode(incomplete)
        }

        var v1Magic = encoded
        v1Magic[3] = Character("1").asciiValue!
        #expect(throws: DoryRendererWorkerContractError.invalidMagic) {
            _ = try DoryRendererWorkerBootstrapCodec.decode(v1Magic)
        }

        var v1Version = encoded
        writeUInt16(1, to: &v1Version, at: 4)
        #expect(throws: DoryRendererWorkerContractError.unsupportedVersion(1)) {
            _ = try DoryRendererWorkerBootstrapCodec.decode(v1Version)
        }

        var zeroCodeDirectoryHash = encoded
        zeroCodeDirectoryHash.replaceSubrange(172..<192, with: repeatElement(0, count: 20))
        #expect(throws: DoryRendererWorkerContractError.invalidCodeDirectoryHash(
            field: "rendererWorkerCodeDirectoryHash"
        )) {
            _ = try DoryRendererWorkerBootstrapCodec.decode(zeroCodeDirectoryHash)
        }
    }

    @Test func commandRoundTripOwnsBoundedDescriptorRegions() throws {
        let region = try DoryRendererSharedRegionReference(
            identity: DoryRendererSharedRegionID(rawValue: fixedUUID(2)),
            descriptorIndex: 0,
            access: .readWrite,
            offset: 4_096,
            length: 65_536,
            declaredFileSize: 1_048_576
        )
        let command = try DoryRendererWorkerCommand(
            generation: DoryRendererWorkerGeneration(rawValue: 7),
            requestID: 9,
            operation: .attachBacking,
            resourceID: 42,
            resourceGeneration: 1,
            deadlineUptimeNanoseconds: 123_456,
            sharedRegions: [region]
        )
        let encoded = try DoryRendererWorkerCommandCodec.encode(command)
        #expect(try DoryRendererWorkerCommandCodec.decode(encoded) == command)
        try command.validateOutOfBandDescriptorCount(1)
        #expect(throws: DoryRendererWorkerContractError.descriptorCountMismatch(
            expected: 1,
            actual: 0
        )) {
            try command.validateOutOfBandDescriptorCount(0)
        }

        let resource3D = try DoryRendererResource3DCreatePayload(
            target: 2,
            format: 1,
            bind: 10,
            width: 64,
            height: 64,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 0
        )
        let createResource3D = try DoryRendererWorkerCommand(
            generation: DoryRendererWorkerGeneration(rawValue: 7),
            requestID: 10,
            operation: .createResource3D,
            resourceID: 43,
            deadlineUptimeNanoseconds: 123_456,
            payload: resource3D.encoded
        )
        #expect(DoryRendererWorkerOperation(rawValue: 6) == .createResource3D)
        #expect(
            try DoryRendererWorkerCommandCodec.decode(
                DoryRendererWorkerCommandCodec.encode(createResource3D)
            ) == createResource3D
        )

        for rawOperation: UInt16 in [999] {
            var unknownOperation = encoded
            writeUInt16(rawOperation, to: &unknownOperation, at: 12)
            #expect(throws: DoryRendererWorkerContractError.unknownOperation(rawOperation)) {
                _ = try DoryRendererWorkerCommandCodec.decode(unknownOperation)
            }
        }
    }

    @Test func resource3DBoundsPipeBufferBytesWithoutRelaxingTextureDimensions() throws {
        let bufferByteCount: UInt32 = 128 * 1_024 * 1_024
        let buffer = try DoryRendererResource3DCreatePayload(
            target: DoryRendererResource3DCreatePayload.pipeBufferTarget,
            format: 1,
            bind: 1,
            width: bufferByteCount,
            height: 1,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 0,
            maximumReferencedBytes: 256 * 1_024 * 1_024
        )
        #expect(try DoryRendererResource3DCreatePayload.decode(
            buffer.encoded,
            maximumReferencedBytes: 256 * 1_024 * 1_024
        ) == buffer)
        #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
            operation: .createResource3D
        )) {
            _ = try DoryRendererResource3DCreatePayload.decode(
                buffer.encoded,
                maximumReferencedBytes: 64 * 1_024 * 1_024
            )
        }
        #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
            operation: .createResource3D
        )) {
            _ = try DoryRendererResource3DCreatePayload(
                target: 2,
                format: 1,
                bind: 1,
                width: bufferByteCount,
                height: 1,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 0
            )
        }
        #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
            operation: .createResource3D
        )) {
            _ = try DoryRendererResource3DCreatePayload(
                target: DoryRendererResource3DCreatePayload.pipeBufferTarget,
                format: 1,
                bind: 1,
                width: 4_096,
                height: DoryRendererResource3DCreatePayload.maximumTextureDimension + 1,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 0
            )
        }
    }

    @Test func fencePayloadAdmitsCanonicalGlobalAndContextTimelinesOnly() throws {
        let globalID = UInt64(UInt32.max) + 0x1234
        let global = try DoryRendererFencePayload(flags: 0, ringIndex: 0, fenceID: globalID)
        #expect(!global.isContextTimeline)
        #expect(try DoryRendererFencePayload.decode(global.encoded) == global)

        let context = try DoryRendererFencePayload(
            flags: DoryRendererFencePayload.contextTimeline,
            ringIndex: 7,
            fenceID: 99
        )
        #expect(context.isContextTimeline)
        #expect(try DoryRendererFencePayload.decode(context.encoded) == context)

        for (flags, ring, fence): (UInt32, UInt32, UInt64) in [
            (0, 1, 1),
            (DoryRendererFencePayload.contextTimeline << 1, 0, 1),
            (
                DoryRendererFencePayload.contextTimeline,
                DoryRendererFencePayload.maximumRingIndex + 1,
                1
            ),
            (0, 0, 0),
        ] {
            #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .createFence
            )) {
                _ = try DoryRendererFencePayload(
                    flags: flags,
                    ringIndex: ring,
                    fenceID: fence
                )
            }
        }
    }

    @Test func commandV3CarriesMoreThanUInt16FragmentedRegionsWithoutExpandingAuthority() throws {
        let regionCount = Int(UInt16.max) + 1
        let regions = try (0..<regionCount).map { index in
            try DoryRendererSharedRegionReference(
                identity: DoryRendererSharedRegionID(rawValue: indexedUUID(UInt32(index + 1))),
                descriptorIndex: 0,
                access: .readWrite,
                offset: UInt64(index),
                length: 1,
                declaredFileSize: UInt64(regionCount)
            )
        }
        let command = try DoryRendererWorkerCommand(
            generation: DoryRendererWorkerGeneration(rawValue: 7),
            requestID: 12,
            operation: .attachBacking,
            resourceID: 42,
            resourceGeneration: 1,
            deadlineUptimeNanoseconds: 123_456,
            sharedRegions: regions
        )

        let encoded = try DoryRendererWorkerCommandCodec.encode(command)
        let encodedCount = UInt32(encoded[56])
            | UInt32(encoded[57]) << 8
            | UInt32(encoded[58]) << 16
            | UInt32(encoded[59]) << 24
        #expect(encodedCount == UInt32(regionCount))
        #expect(try DoryRendererWorkerCommandCodec.decode(encoded).sharedRegions.count == regionCount)
        #expect(
            DoryRendererWorkerLimits.production.maximumSharedRegions
                == Int(DoryRendererWorkerLimits.production.maximumScanoutBytes / 4_096)
        )

        var v1 = encoded
        writeUInt16(1, to: &v1, at: 4)
        #expect(throws: DoryRendererWorkerContractError.unsupportedVersion(1)) {
            _ = try DoryRendererWorkerCommandCodec.decode(v1)
        }
    }

    @Test func zeroBlobIDIsReservedForExactRendererAllocatedSHM() throws {
        let rendererSHM = try DoryRendererBlobCreatePayload(
            blobMemory: 2,
            blobFlags: 1,
            blobID: 0,
            size: 4_096
        )
        #expect(try DoryRendererBlobCreatePayload.decode(rendererSHM.encoded) == rendererSHM)

        for (memory, flags): (UInt32, UInt32) in [(2, 3), (2, 0), (1, 1)] {
            #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .createBlob
            )) {
                _ = try DoryRendererBlobCreatePayload(
                    blobMemory: memory,
                    blobFlags: flags,
                    blobID: 0,
                    size: 4_096
                )
            }
        }
    }

    @Test func discontiguousRegionsShareOneDescriptorWithoutLosingIOVecOrder() throws {
        let first = try DoryRendererSharedRegionReference(
            identity: DoryRendererSharedRegionID(rawValue: fixedUUID(20)),
            descriptorIndex: 0,
            access: .readWrite,
            offset: 8_192,
            length: 4_096,
            declaredFileSize: 1_048_576
        )
        let second = try DoryRendererSharedRegionReference(
            identity: DoryRendererSharedRegionID(rawValue: fixedUUID(21)),
            descriptorIndex: 0,
            access: .readWrite,
            offset: 1_024,
            length: 2_048,
            declaredFileSize: 1_048_576
        )
        let command = try DoryRendererWorkerCommand(
            generation: DoryRendererWorkerGeneration(rawValue: 7),
            requestID: 10,
            operation: .attachBacking,
            resourceID: 42,
            resourceGeneration: 1,
            deadlineUptimeNanoseconds: 123_456,
            sharedRegions: [first, second]
        )
        #expect(command.requiredOutOfBandDescriptorCount == 1)
        try command.validateOutOfBandDescriptorCount(1)
        let decoded = try DoryRendererWorkerCommandCodec.decode(
            DoryRendererWorkerCommandCodec.encode(command)
        )
        #expect(decoded.sharedRegions.map(\.offset) == [8_192, 1_024])

        let conflicting = try DoryRendererSharedRegionReference(
            identity: DoryRendererSharedRegionID(rawValue: fixedUUID(22)),
            descriptorIndex: 0,
            access: .readOnly,
            offset: 0,
            length: 4,
            declaredFileSize: 1_048_576
        )
        #expect(throws: DoryRendererWorkerContractError.invalidSharedRegionBounds) {
            _ = try DoryRendererWorkerCommand(
                generation: DoryRendererWorkerGeneration(rawValue: 7),
                requestID: 11,
                operation: .attachBacking,
                resourceID: 43,
                resourceGeneration: 1,
                deadlineUptimeNanoseconds: 123_456,
                sharedRegions: [first, conflicting]
            )
        }
    }

    @Test func submit3DCommandStreamIsDescriptorBackedNotXPCData() throws {
        let region = try DoryRendererSharedRegionReference(
            identity: DoryRendererSharedRegionID(rawValue: fixedUUID(3)),
            descriptorIndex: 0,
            access: .readOnly,
            offset: 4_096,
            length: 256 * 1_024,
            declaredFileSize: 512 * 1_024
        )
        let command = try DoryRendererWorkerCommand(
            generation: DoryRendererWorkerGeneration(rawValue: 7),
            requestID: 10,
            operation: .submit3D,
            contextID: 5,
            deadlineUptimeNanoseconds: 123_456,
            sharedRegions: [region]
        )
        let encoded = try DoryRendererWorkerCommandCodec.encode(command)
        #expect(encoded.count == DoryRendererWorkerCommandCodec.headerByteCount
            + DoryRendererWorkerCommandCodec.sharedRegionByteCount)
        #expect(UInt64(encoded.count) < region.length)
        #expect(try DoryRendererWorkerCommandCodec.decode(encoded) == command)

        #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
            operation: .submit3D
        )) {
            _ = try DoryRendererWorkerCommand(
                generation: DoryRendererWorkerGeneration(rawValue: 7),
                requestID: 11,
                operation: .submit3D,
                contextID: 5,
                deadlineUptimeNanoseconds: 123_456,
                payload: Data(repeating: 0, count: 4)
            )
        }

        let writableRegion = try DoryRendererSharedRegionReference(
            identity: DoryRendererSharedRegionID(rawValue: fixedUUID(4)),
            descriptorIndex: 0,
            access: .readWrite,
            offset: 0,
            length: 4,
            declaredFileSize: 4
        )
        #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
            operation: .submit3D
        )) {
            _ = try DoryRendererWorkerCommand(
                generation: DoryRendererWorkerGeneration(rawValue: 7),
                requestID: 12,
                operation: .submit3D,
                contextID: 5,
                deadlineUptimeNanoseconds: 123_456,
                sharedRegions: [writableRegion]
            )
        }
    }

    @Test func scanoutLeaseCarriesProducerCompleteSHMAndReleaseAuthority() throws {
        let lease = try makeLease()
        let encoded = DoryRendererScanoutLeaseCodec.encode(lease)
        #expect(try DoryRendererScanoutLeaseCodec.decode(encoded) == lease)
        try lease.validateOutOfBandDescriptorCount(1)
        #expect(throws: DoryRendererWorkerContractError.invalidScanoutGeometry) {
            _ = try makeLease(stride: 7_681)
        }
    }

    @Test func scanoutAcquireCarriesCanonicalValidatedLinearLayout() throws {
        let payload = try DoryRendererScanoutAcquirePayload(
            width: 1_280,
            height: 800,
            virglFormat: 1,
            stride: 5_120,
            storageOffset: 0
        )
        #expect(try DoryRendererScanoutAcquirePayload.decode(payload.encoded) == payload)

        for reservedOffset in [20, 24] {
            var forged = [UInt8](payload.encoded)
            forged[reservedOffset] = 1
            #expect(throws: DoryRendererWorkerContractError.invalidOperationPayload(
                operation: .acquireScanoutLease
            )) {
                _ = try DoryRendererScanoutAcquirePayload.decode(Data(forged))
            }
        }
    }

    @Test func receiptFailsClosedUnlessEveryAccelerationProofIsPresent() throws {
        let bootstrap = try makeBootstrap()
        let virgl2 = try capset(id: 2, seed: 20)
        let venus = try capset(id: 4, seed: 40)
        let complete = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [venus, virgl2]
        )
        #expect(complete.productionAccelerationIsAdmissible)
        #expect(complete.capsets.map(\.id) == [2, 4])
        let encoded = DoryRendererCapabilityReceiptCodec.encode(complete)
        #expect(
            try DoryRendererCapabilityReceiptCodec.decode(
                encoded,
                accepting: bootstrap
            ) == complete
        )

        let missingFence = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration.subtracting(.rendererFenceDescriptor),
            capsets: [virgl2, venus]
        )
        #expect(!missingFence.productionAccelerationIsAdmissible)
        let missingVirgl2 = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [venus]
        )
        #expect(!missingVirgl2.productionAccelerationIsAdmissible)
        let missingVenus = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [virgl2]
        )
        #expect(!missingVenus.productionAccelerationIsAdmissible)
        #expect(throws: DoryRendererWorkerContractError.unknownFlags(1 << 11)) {
            _ = try DoryRendererCapabilityReceipt(
                accepting: bootstrap,
                features: DoryRendererWorkerFeatures(rawValue: 1 << 11),
                capsets: [virgl2, venus]
            )
        }
        let synchronousFallback = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration.subtracting(.asynchronousGPUCompletion),
            capsets: [virgl2, venus]
        )
        #expect(!synchronousFallback.productionAccelerationIsAdmissible)
        let frameCopyFallback = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration.subtracting(.zeroCopyDescriptorBackedScanout),
            capsets: [virgl2, venus]
        )
        #expect(!frameCopyFallback.productionAccelerationIsAdmissible)
        let missingSharedTexture = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration.subtracting(
                .zeroCopySharedTextureMetalScanout
            ),
            capsets: [virgl2, venus]
        )
        #expect(!missingSharedTexture.productionAccelerationIsAdmissible)
    }

    @Test func receiptBindsExactCapsetBytesAndRejectsMalformedAuthority() throws {
        let bootstrap = try makeBootstrap()
        let virgl2 = try capset(id: 2, seed: 20)
        let venus = try capset(id: 4, seed: 40)
        let receipt = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [virgl2, venus]
        )
        let encoded = DoryRendererCapabilityReceiptCodec.encode(receipt)
        let decoded = try DoryRendererCapabilityReceiptCodec.decode(
            encoded,
            accepting: bootstrap
        )
        #expect(decoded.productionAccelerationIsAdmissible)
        #expect(decoded.capsets[0].data == Data(repeating: 20, count: 4_096))
        #expect(decoded.capsets[1].data == Data(repeating: 40, count: 4_096))

        var badDigest = encoded
        badDigest[DoryRendererCapabilityReceiptCodec.headerByteCount + 16] ^= 0xff
        #expect(throws: DoryRendererWorkerContractError.incompleteCapabilityReceipt) {
            _ = try DoryRendererCapabilityReceiptCodec.decode(
                badDigest,
                accepting: bootstrap
            )
        }

        var impossibleLength = encoded
        writeUInt32(
            UInt32(DoryRendererCapsetAttestation.maximumCapsetBytes + 1),
            to: &impossibleLength,
            at: DoryRendererCapabilityReceiptCodec.headerByteCount + 8
        )
        #expect(throws: DoryRendererWorkerContractError.invalidCapsetSize(
            limit: DoryRendererCapsetAttestation.maximumCapsetBytes,
            actual: DoryRendererCapsetAttestation.maximumCapsetBytes + 1
        )) {
            _ = try DoryRendererCapabilityReceiptCodec.decode(
                impossibleLength,
                accepting: bootstrap
            )
        }

        var truncated = encoded
        truncated.removeLast()
        writeUInt32(UInt32(truncated.count), to: &truncated, at: 8)
        #expect(throws: DoryRendererWorkerContractError.invalidCapsetSize(
            limit: DoryRendererCapsetAttestation.maximumCapsetBytes,
            actual: 4_096
        )) {
            _ = try DoryRendererCapabilityReceiptCodec.decode(
                truncated,
                accepting: bootstrap
            )
        }

        #expect(throws: DoryRendererWorkerContractError.invalidCapsetCount(
            limit: 2,
            actual: 3
        )) {
            _ = try DoryRendererCapabilityReceipt(
                accepting: bootstrap,
                features: .productionAcceleration,
                capsets: [virgl2, venus, venus]
            )
        }
        let venusVersionZero = try DoryRendererCapsetAttestation(
            id: 4,
            maximumVersion: 0,
            data: Data([1])
        )
        #expect(venusVersionZero.maximumVersion == 0)
        #expect(throws: DoryRendererWorkerContractError.invalidCapsetVersion(
            id: 4,
            maximumVersion: 1
        )) {
            _ = try DoryRendererCapsetAttestation(
                id: 4,
                maximumVersion: 1,
                data: Data([1])
            )
        }
        let virgl2VersionOne = try DoryRendererCapsetAttestation(
            id: 2,
            maximumVersion: 1,
            data: Data([1])
        )
        #expect(virgl2VersionOne.maximumVersion == 1)
        #expect(throws: DoryRendererWorkerContractError.invalidCapsetVersion(
            id: 2,
            maximumVersion: 0
        )) {
            _ = try DoryRendererCapsetAttestation(
                id: 2,
                maximumVersion: 0,
                data: Data([1])
            )
        }

        let oversizedAggregate = Data(
            count: DoryRendererCapabilityReceiptCodec.maximumFrameBytes + 1
        )
        #expect(throws: DoryRendererWorkerContractError.frameTooLarge(
            limit: DoryRendererCapabilityReceiptCodec.maximumFrameBytes,
            actual: DoryRendererCapabilityReceiptCodec.maximumFrameBytes + 1
        )) {
            _ = try DoryRendererCapabilityReceiptCodec.decode(
                oversizedAggregate,
                accepting: bootstrap
            )
        }
    }

    @Test func signingRequirementsPinExactRunnerAndWorkerPeers() {
        #expect(DoryRendererWorkerIdentity.workerCodeSigningRequirement.contains(
            DoryRendererWorkerIdentity.workerBundleIdentifier
        ))
        #expect(DoryRendererWorkerIdentity.workerCodeSigningRequirement.contains("864H636QW4"))
        #expect(!DoryRendererWorkerIdentity.workerCodeSigningRequirement.contains("*"))
        #expect(DoryRendererWorkerIdentity.runnerCodeSigningRequirement.contains(
            DoryRendererWorkerIdentity.runnerBundleIdentifier
        ))
    }

    @Test func xpcInterfaceAllowsOnlyDescriptorsAndOneSharedTextureHandle() {
        let interface = DoryRendererWorkerXPCInterface.make()
        let selector = #selector(
            DoryRendererWorkerXPCProtocol.exchange(_:descriptors:withReply:)
        )
        let expectedClasses = NSSet(
            objects: NSArray.self,
            FileHandle.self
        ) as! Set<AnyHashable>

        #expect(interface.classes(
            for: selector,
            argumentIndex: 1,
            ofReply: false
        ) == expectedClasses)
        #expect(interface.classes(
            for: selector,
            argumentIndex: 1,
            ofReply: true
        ) == expectedClasses)
        let expectedTextureClasses = NSSet(
            objects: MTLSharedTextureHandle.self
        ) as! Set<AnyHashable>
        #expect(interface.classes(
            for: selector,
            argumentIndex: 2,
            ofReply: true
        ) == expectedTextureClasses)
    }

    private func makeBootstrap() throws -> DoryRendererWorkerBootstrap {
        try DoryRendererWorkerBootstrap(
            workspaceID: DoryRendererWorkspaceID(rawValue: fixedUUID(1)),
            generation: DoryRendererWorkerGeneration(rawValue: 1),
            sourceTuple: .productionCandidate,
            producerFenceContract: .managedLinux61230PrepareFBV1,
            requestedCapabilities: .productionAcceleration,
            artifacts: DoryRendererArtifactManifest(
                candidateInventory: digest(1),
                managedGuestKernel: digest(2),
                guestMesa: digest(3),
                rendererWorkerExecutable: digest(4),
                rendererWorkerCodeDirectoryHash: try codeDirectoryHash(5)
            )
        )
    }

    private func makeLease(stride: UInt32 = 7_680) throws -> DoryRendererScanoutLease {
        try DoryRendererScanoutLease(
            workerGeneration: DoryRendererWorkerGeneration(rawValue: 4),
            resourceID: 77,
            resourceGeneration: 9,
            leaseID: DoryRendererScanoutLeaseID(rawValue: fixedUUID(10)),
            releaseToken: DoryRendererScanoutReleaseToken(rawValue: fixedUUID(11)),
            sharedRegionID: DoryRendererSharedRegionID(rawValue: fixedUUID(12)),
            sharedMemoryDescriptorIndex: 0,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: true,
            width: 1_920,
            height: 1_080,
            stride: stride,
            rowAlignment: 256,
            storageOffset: 0,
            declaredFileSize: UInt64(stride) * 1_080,
            leaseByteCount: UInt64(stride) * 1_080
        )
    }

    private func capset(id: UInt32, seed: UInt8) throws -> DoryRendererCapsetAttestation {
        try DoryRendererCapsetAttestation(
            id: id,
            maximumVersion: id == 2 ? 2 : 0,
            data: Data(repeating: seed, count: 4_096)
        )
    }

    private func digest(_ seed: UInt8) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(bytes: Data(repeating: seed, count: 32))
    }

    private func codeDirectoryHash(_ seed: UInt8) throws -> DoryCodeDirectoryHash {
        try DoryCodeDirectoryHash(bytes: Data(repeating: seed, count: 20))
    }

    private func fixedUUID(_ lastByte: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, lastByte))
    }

    private func indexedUUID(_ value: UInt32) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ))
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
