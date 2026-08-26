import Darwin
import DoryRendererWorkerContracts
import DoryRendererWorkerServiceCore
@testable import DoryRendererWorkerVirglBackend
import DoryVirglRendererShim
import Foundation
import Metal
import Testing

@Suite struct DoryRendererWorkerVirglBackendTests {
    @Test func submitDecoderDiagnosticAcceptsOnlyExactPinnedCommandMessages() {
        var diagnostic = DoryVirglRendererSubmitDiagnostic()
        let accepted = "context 7 failed to dispatch PIPE_RESOURCE_CREATE: 22\n"
            .withCString {
                DoryVirglRendererClassifySubmitDiagnosticMessage($0, 7, &diagnostic)
            }
        #expect(accepted == 1)
        #expect(diagnostic.valid == 1)
        #expect(diagnostic.context_id == 7)
        #expect(diagnostic.command_id == 48)
        #expect(diagnostic.status == 22)
        #expect(diagnostic.failed_command_location_disposition == 0)
        #expect(diagnostic.failed_command_dword_offset == 0)
        #expect(diagnostic.failed_command_ordinal == 0)

        let rejected = [
            "context 8 failed to dispatch PIPE_RESOURCE_CREATE: 22\n",
            "context 7 failed to dispatch GUEST_SHADER_SOURCE: 22\n",
            "context 7 failed to dispatch PIPE_RESOURCE_CREATE: 22 trailing\n",
            "Shader failed to compile\nGLSL:\nuser-controlled-source",
            "/private/tmp/renderer-path",
        ]
        for message in rejected {
            diagnostic = DoryVirglRendererSubmitDiagnostic()
            let result = message.withCString {
                DoryVirglRendererClassifySubmitDiagnosticMessage($0, 7, &diagnostic)
            }
            #expect(result == 0)
            #expect(diagnostic.valid == 0)
        }
    }

    @Test func exactSubmitDecoderDiagnosticAcceptsOnlyCanonicalMachineGrammar() {
        var diagnostic = DoryVirglRendererSubmitDiagnostic()
        let accepted = "vrend-dispatch-error context=7 command=1 dword-offset=3 command-ordinal=2 status=22 surface-reason=7\n"
            .withCString {
                DoryVirglRendererClassifyExactSubmitDiagnosticMessage(
                    $0,
                    7,
                    &diagnostic
                )
            }
        #expect(accepted == 1)
        #expect(diagnostic.valid == 1)
        #expect(diagnostic.context_id == 7)
        #expect(diagnostic.command_id == 1)
        #expect(diagnostic.status == 22)
        #expect(diagnostic.failed_command_location_disposition == 1)
        #expect(diagnostic.failed_command_dword_offset == 3)
        #expect(diagnostic.failed_command_ordinal == 2)
        #expect(diagnostic.surface_failure_reason == 7)

        let malformed = [
            "vrend-dispatch-error context=8 command=1 dword-offset=3 command-ordinal=2 status=22 surface-reason=0\n",
            "vrend-dispatch-error context=07 command=1 dword-offset=3 command-ordinal=2 status=22 surface-reason=0\n",
            "vrend-dispatch-error context=7 command=64 dword-offset=3 command-ordinal=2 status=22 surface-reason=0\n",
            "vrend-dispatch-error context=7 command=1 dword-offset=03 command-ordinal=2 status=22 surface-reason=0\n",
            "vrend-dispatch-error context=7 command=1 dword-offset=3 command-ordinal=2 status=-0 surface-reason=0\n",
            "vrend-dispatch-error context=7 command=1 dword-offset=3 command-ordinal=2 status=22\n",
            "vrend-dispatch-error context=7 command=1 dword-offset=3 command-ordinal=2 status=22 surface-reason=08\n",
            "vrend-dispatch-error context=7 command=1 dword-offset=3 command-ordinal=2 status=22 surface-reason=8\n",
            "vrend-dispatch-error context=7 command=1 dword-offset=3 command-ordinal=2 status=22 surface-reason=0 trailing\n",
        ]
        for message in malformed {
            diagnostic = DoryVirglRendererSubmitDiagnostic()
            let result = message.withCString {
                DoryVirglRendererClassifyExactSubmitDiagnosticMessage(
                    $0,
                    7,
                    &diagnostic
                )
            }
            #expect(result == -EINVAL)
            #expect(diagnostic.valid == 0)
            #expect(diagnostic.failed_command_location_disposition == 2)
            #expect(diagnostic.failed_command_dword_offset == 0)
            #expect(diagnostic.failed_command_ordinal == 0)
        }

        diagnostic = DoryVirglRendererSubmitDiagnostic()
        let unrelated = "context 7 failed to dispatch CREATE_OBJECT: 22\n".withCString {
            DoryVirglRendererClassifyExactSubmitDiagnosticMessage($0, 7, &diagnostic)
        }
        #expect(unrelated == 0)
        #expect(diagnostic.failed_command_location_disposition == 0)
    }

    @Test func exactDecoderTupleCorrelatesOnlyOneMatchingHeaderBoundary() {
        func header(
            commandID: UInt32,
            objectType: UInt32 = 0,
            payloadDwords: UInt32 = 0
        ) -> UInt32 {
            commandID | (objectType << 8) | (payloadDwords << 16)
        }
        let dwords: [UInt32] = [
            header(commandID: 1, objectType: 1, payloadDwords: 1),
            0xd0f0_cafe,
            header(commandID: 0),
            header(commandID: 1, objectType: 4),
        ]
        func correlate(
            disposition: UInt32 = 1,
            offset: UInt32,
            ordinal: UInt32,
            commandID: UInt32 = 1
        ) -> DoryVirglRendererSubmitDiagnostic {
            var diagnostic = DoryVirglRendererSubmitDiagnostic()
            diagnostic.valid = 1
            diagnostic.command_id = commandID
            diagnostic.status = 22
            diagnostic.failed_command_location_disposition = disposition
            diagnostic.failed_command_dword_offset = offset
            diagnostic.failed_command_ordinal = ordinal
            diagnostic.surface_failure_reason = 4
            let status = dwords.withUnsafeBytes { bytes in
                DoryVirglRendererCorrelateCreateObjectSubtype(
                    bytes.baseAddress,
                    UInt32(dwords.count),
                    &diagnostic
                )
            }
            #expect(status == 0)
            return diagnostic
        }

        let exact = correlate(offset: 3, ordinal: 2)
        #expect(exact.failed_command_location_disposition == 1)
        #expect(exact.failed_command_dword_offset == 3)
        #expect(exact.failed_command_ordinal == 2)
        #expect(exact.create_object_subtype_disposition == 1)
        #expect(exact.create_object_subtype == 4)
        #expect(exact.create_object_candidate_count == 1)
        #expect(exact.create_object_subtype_mask == 1 << 4)
        #expect(exact.surface_failure_reason == 0)

        for rejected in [
            correlate(offset: 3, ordinal: 1),
            correlate(offset: 1, ordinal: 0),
            correlate(offset: 2, ordinal: 1),
            correlate(disposition: UInt32.max, offset: 3, ordinal: 2),
        ] {
            #expect(rejected.failed_command_location_disposition == 2)
            #expect(rejected.failed_command_dword_offset == 0)
            #expect(rejected.failed_command_ordinal == 0)
            #expect(rejected.valid == 0)
            #expect(rejected.create_object_subtype_disposition == 0)
            #expect(rejected.create_object_subtype == 0)
            #expect(rejected.create_object_candidate_count == 0)
            #expect(rejected.create_object_subtype_mask == 0)
            #expect(rejected.surface_failure_reason == 0)
        }


        let stopsAtFailedHeader: [UInt32] = [
            header(commandID: 1, objectType: 4),
            header(commandID: 1, objectType: 4, payloadDwords: 2),
        ]
        var stopsDiagnostic = DoryVirglRendererSubmitDiagnostic()
        stopsDiagnostic.valid = 1
        stopsDiagnostic.command_id = 1
        stopsDiagnostic.failed_command_location_disposition = 1
        stopsDiagnostic.failed_command_dword_offset = 0
        stopsDiagnostic.failed_command_ordinal = 0
        let stopsStatus = stopsAtFailedHeader.withUnsafeBytes { bytes in
            DoryVirglRendererCorrelateCreateObjectSubtype(
                bytes.baseAddress,
                UInt32(stopsAtFailedHeader.count),
                &stopsDiagnostic
            )
        }
        #expect(stopsStatus == 0)
        #expect(stopsDiagnostic.valid == 1)
        #expect(stopsDiagnostic.create_object_subtype_disposition == 1)
        #expect(stopsDiagnostic.create_object_subtype == 4)

        let surfaceDwords = [header(commandID: 1, objectType: 8)]
        func correlateSurface(status: Int32) -> DoryVirglRendererSubmitDiagnostic {
            var diagnostic = DoryVirglRendererSubmitDiagnostic()
            diagnostic.valid = 1
            diagnostic.command_id = 1
            diagnostic.status = status
            diagnostic.failed_command_location_disposition = 1
            diagnostic.surface_failure_reason = 4
            let correlationStatus = surfaceDwords.withUnsafeBytes { bytes in
                DoryVirglRendererCorrelateCreateObjectSubtype(
                    bytes.baseAddress,
                    UInt32(surfaceDwords.count),
                    &diagnostic
                )
            }
            #expect(correlationStatus == 0)
            return diagnostic
        }
        let surface = correlateSurface(status: EINVAL)
        #expect(surface.create_object_subtype == 8)
        #expect(surface.surface_failure_reason == 4)
        #expect(correlateSurface(status: ENOMEM).surface_failure_reason == 0)
    }

    @Test func createObjectHeaderClassifierSummarizesWithoutGuessingFailedSubtype() {
        func header(
            commandID: UInt32,
            objectType: UInt32 = 0,
            payloadDwords: UInt32 = 0
        ) -> UInt32 {
            commandID | (objectType << 8) | (payloadDwords << 16)
        }
        func classify(_ dwords: [UInt32]) -> DoryVirglRendererSubmitDiagnostic {
            var diagnostic = DoryVirglRendererSubmitDiagnostic()
            let status = dwords.withUnsafeBytes { bytes in
                DoryVirglRendererClassifyCreateObjectSubtype(
                    bytes.baseAddress,
                    UInt32(dwords.count),
                    &diagnostic
                )
            }
            #expect(status == 0)
            return diagnostic
        }

        let payloadMarker: UInt32 = 0xd0f0_cafe
        let unique = classify([
            header(commandID: 1, objectType: 4, payloadDwords: 2),
            0x1234_5678,
            payloadMarker,
        ])
        #expect(unique.create_object_subtype_disposition == 0)
        #expect(unique.create_object_subtype == 0)
        #expect(unique.create_object_candidate_count == 1)
        #expect(unique.create_object_subtype_mask == 1 << 4)
        #expect(unique.valid == 0)
        #expect(unique.precursor_category == 0)
        #expect(unique.surface_failure_reason == 0)
        #expect(!String(reflecting: unique).contains(String(payloadMarker, radix: 16)))

        let absent = classify([header(commandID: 0)])
        #expect(absent.create_object_subtype_disposition == 0)
        #expect(absent.create_object_subtype == 0)
        #expect(absent.create_object_candidate_count == 0)
        #expect(absent.create_object_subtype_mask == 0)

        let multiple = classify([
            header(commandID: 1, objectType: 1),
            header(commandID: 1, objectType: 4),
        ])
        #expect(multiple.create_object_subtype_disposition == 0)
        #expect(multiple.create_object_subtype == 0)
        #expect(multiple.create_object_candidate_count == 2)
        #expect(multiple.create_object_subtype_mask == (1 << 1) | (1 << 4))

        let malformed = classify([
            header(commandID: 1, objectType: 4, payloadDwords: 2),
            0x1234_5678,
        ])
        #expect(malformed.create_object_subtype_disposition == 0)
        #expect(malformed.create_object_subtype == 0)
        #expect(malformed.create_object_candidate_count == 0)
        #expect(malformed.create_object_subtype_mask == 0)

        let outsidePinnedEnum = classify([
            header(commandID: 1, objectType: 12),
        ])
        #expect(outsidePinnedEnum.create_object_subtype_disposition == 0)
        #expect(outsidePinnedEnum.create_object_subtype == 0)
        #expect(outsidePinnedEnum.create_object_candidate_count == 1)
        #expect(outsidePinnedEnum.create_object_subtype_mask == 0)
    }

    @Test func submitPrecursorClassifierDiscardsUntrustedSuffix() throws {
        let rawGuestSuffix = "DORY_RAW_GUEST_SHADER_SOURCE_/private/tmp/secret"
        let category = ("Shader failed to compile\n" + rawGuestSuffix).withCString {
            DoryVirglRendererClassifySubmitPrecursorMessage($0)
        }
        #expect(category == 1)
        #expect("Error assigning TGSI\n".withCString {
            DoryVirglRendererClassifySubmitPrecursorMessage($0)
        } == 2)
        #expect(rawGuestSuffix.withCString {
            DoryVirglRendererClassifySubmitPrecursorMessage($0)
        } == 0)
        #expect("/private/tmp/renderer-path".withCString {
            DoryVirglRendererClassifySubmitPrecursorMessage($0)
        } == 0)

        var shimDiagnostic = DoryVirglRendererSubmitDiagnostic()
        shimDiagnostic.precursor_category = category
        let sanitized = try #require(
            DoryRendererForeignSubmitFailure(sanitizing: shimDiagnostic)
        )
        #expect(!sanitized.decoderDiagnosticIsAvailable)
        #expect(sanitized.contextID == 0)
        #expect(sanitized.commandID == 0)
        #expect(sanitized.createObjectSubtypeDisposition == .absent)
        #expect(sanitized.createObjectSubtype == nil)
        #expect(sanitized.surfaceFailureReason == .none)
        #expect(sanitized.precursorCategory == .shaderCompileFailed)
        #expect(!String(reflecting: sanitized).contains(rawGuestSuffix))
    }

    @Test func submitDiagnosticSanitizesUnknownSubtypeAndPrecursorValues() throws {
        var shimDiagnostic = DoryVirglRendererSubmitDiagnostic()
        shimDiagnostic.valid = 1
        shimDiagnostic.context_id = 2
        shimDiagnostic.command_id = 1
        shimDiagnostic.status = 22
        shimDiagnostic.create_object_subtype_disposition = 1
        shimDiagnostic.create_object_subtype = 12
        shimDiagnostic.surface_failure_reason = UInt32.max
        shimDiagnostic.precursor_category = UInt32.max

        let sanitized = try #require(
            DoryRendererForeignSubmitFailure(sanitizing: shimDiagnostic)
        )
        #expect(sanitized.decoderDiagnosticIsAvailable)
        #expect(sanitized.createObjectSubtypeDisposition == .ambiguous)
        #expect(sanitized.createObjectSubtype == nil)
        #expect(sanitized.surfaceFailureReason == .none)
        #expect(sanitized.precursorCategory == .none)
    }

    @Test func submitDiagnosticCarriesOnlyCorrelatedSurfaceFailureReason() throws {
        var shimDiagnostic = DoryVirglRendererSubmitDiagnostic()
        shimDiagnostic.valid = 1
        shimDiagnostic.context_id = 2
        shimDiagnostic.command_id = 1
        shimDiagnostic.status = EINVAL
        shimDiagnostic.failed_command_location_disposition = 1
        shimDiagnostic.create_object_subtype_disposition = 1
        shimDiagnostic.create_object_subtype = 8
        shimDiagnostic.create_object_candidate_count = 1
        shimDiagnostic.create_object_subtype_mask = 1 << 8
        shimDiagnostic.surface_failure_reason = 5

        let surface = try #require(
            DoryRendererForeignSubmitFailure(sanitizing: shimDiagnostic)
        )
        #expect(surface.createObjectSubtype == .surface)
        #expect(surface.surfaceFailureReason == .resourceGLObjectMissing)

        shimDiagnostic.create_object_subtype = 4
        shimDiagnostic.create_object_subtype_mask = 1 << 4
        let shader = try #require(
            DoryRendererForeignSubmitFailure(sanitizing: shimDiagnostic)
        )
        #expect(shader.createObjectSubtype == .shader)
        #expect(shader.surfaceFailureReason == .none)
    }

    @Test func submitFailureClassificationCarriesTypedOpcodeWithoutRawText() throws {
        let region = try DoryRendererSharedRegionReference(
            identity: .random(),
            descriptorIndex: 0,
            access: .readOnly,
            offset: 0,
            length: 4,
            declaredFileSize: 4
        )
        let submitted = try command(
            requestID: 41,
            operation: .submit3D,
            contextID: 7,
            sharedRegions: [region]
        )
        let diagnostic = DoryRendererWorkerVirglBackend.executionFailureDiagnostic(
            command: submitted,
            error: DoryRendererForeignSessionError.submitFailed(
                status: 22,
                diagnostic: DoryRendererForeignSubmitFailure(
                    contextID: 7,
                    commandID: 1,
                    status: 22,
                    createObjectSubtypeDisposition: .present,
                    createObjectSubtype: .shader,
                    createObjectCandidateCount: 2,
                    createObjectSubtypeMask: (1 << 4) | (1 << 8),
                    precursorCategory: .shaderCompileFailed
                )
            ),
            elapsedNanoseconds: 3_087_833
        )
        #expect(diagnostic.operation == .submit3D)
        #expect(diagnostic.requestID == 41)
        #expect(diagnostic.stage == .foreignCall)
        #expect(diagnostic.errorCase == .submitFailed)
        #expect(diagnostic.foreignOperation == .submit3D)
        #expect(diagnostic.statusIsAvailable)
        #expect(diagnostic.status == 22)
        #expect(diagnostic.submitDiagnosticIsAvailable)
        #expect(diagnostic.virglDecoderDiagnosticIsAvailable)
        #expect(diagnostic.submitContextID == 7)
        #expect(diagnostic.virglCommandID == 1)
        #expect(diagnostic.virglCommandStatus == 22)
        #expect(diagnostic.createObjectSubtypeDisposition == .present)
        #expect(diagnostic.createObjectSubtype == .shader)
        #expect(diagnostic.createObjectCandidateCount == 2)
        #expect(diagnostic.createObjectSubtypeMask == (1 << 4) | (1 << 8))
        #expect(diagnostic.surfaceFailureReason == .none)
        #expect(diagnostic.virglPrecursorCategory == .shaderCompileFailed)
        #expect(diagnostic.elapsedNanoseconds == 3_087_833)

        let untrusted = DoryRendererWorkerVirglBackend.executionFailureDiagnostic(
            command: submitted,
            error: DoryRendererForeignSessionError.callFailed(
                operation: "guest shader source /private/tmp/secret",
                status: 22
            ),
            elapsedNanoseconds: 1
        )
        #expect(untrusted.foreignOperation == .unclassified)
        #expect(!untrusted.submitDiagnosticIsAvailable)
        #expect(!untrusted.virglDecoderDiagnosticIsAvailable)
        #expect(untrusted.createObjectSubtypeDisposition == .absent)
        #expect(untrusted.createObjectSubtype == nil)
        #expect(untrusted.createObjectCandidateCount == 0)
        #expect(untrusted.createObjectSubtypeMask == 0)
        #expect(untrusted.surfaceFailureReason == .none)
        #expect(untrusted.virglPrecursorCategory == .none)
    }

    @Test func activationAdvertisesVirGL2AndVenusAfterBothPreflights() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)

        let receipt = try backend.activate(bootstrap: makeBootstrap())

        #expect(receipt.productionAccelerationIsAdmissible)
        #expect(receipt.capsets.map(\.id) == [2, 4])
        #expect(receipt.capsets.map(\.maximumVersion) == [2, 0])
        #expect(session.createdContextHistory[0xffff_fff0] == 2)
        #expect(session.createdContextHistory[0xffff_fff1] == 4)
        #expect(session.createdResources3D.count == 3)
        let buffer = try #require(session.createdResources3D.first {
            $0.resourceID == 0xffff_fff4
        })
        #expect(buffer.payload.target == 0)
        #expect(buffer.payload.format == 64)
        #expect(buffer.payload.bind == 1 << 4)
        #expect(buffer.payload.width == 4_096)
        #expect(buffer.payload.height == 1)
        let resource2D = try #require(session.createdResources3D.first {
            $0.resourceID == 0xffff_fff5
        })
        #expect(resource2D.payload.target == 2)
        #expect(resource2D.payload.bind ==
            UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT))
        #expect(resource2D.payload.flags == 1)
        let backing = try #require(session.attachedBackings.first {
            $0.resourceID == 0xffff_fff5
        })
        #expect(backing.iovecCount == 1)
        #expect(backing.firstLength == 64)
        #expect(backing.firstByte == 0xa5)
        let transfer = try #require(session.transfers.first {
            $0.resourceID == 0xffff_fff5
        })
        #expect(transfer.toHost)
        #expect(transfer.contextID == 0)
        let expectedTransferPayload = try DoryRendererTransfer3DPayload(
            level: 0,
            stride: 0,
            layerStride: 0,
            offset: 0,
            x: 0,
            y: 0,
            z: 0,
            width: 4,
            height: 4,
            depth: 1
        )
        #expect(transfer.payload == expectedTransferPayload)
        #expect(!transfer.usedExplicitIOVecs)
        #expect(transfer.iovecCount == 0)
        let surfaceSubmit = try #require(session.submissions.first {
            $0.contextID == 0xffff_fff0
        })
        #expect(surfaceSubmit.dwords == [
            0x0005_0801,
            0xffff_fff6,
            0xffff_fff5,
            UInt32(DORY_VIRGL_RENDERER_FORMAT_BGRA8_UNORM),
            0,
            0,
            0x0001_0803,
            0xffff_fff6,
        ])
        #expect(session.attachedResources.contains {
            $0 == (0xffff_fff0, 0xffff_fff5)
        })
        #expect(session.detachedResources.contains {
            $0 == (0xffff_fff0, 0xffff_fff5)
        })
        #expect(session.unreferencedResourceIDs.contains(0xffff_fff5))
        #expect(session.detachedBackingResourceIDs.contains(0xffff_fff5))
        let texture = try #require(session.createdResources3D.first {
            $0.resourceID == 0xffff_fff3
        })
        #expect(texture.payload.width == 4)
        #expect(texture.payload.height == 4)
        #expect(texture.payload.bind &
            UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT) != 0)
        #expect(session.acquiredScanoutResourceIDs == [0xffff_fff3])
        #expect(session.createdBlobs.count == 1)
        #expect(session.createdBlobs[0].payload.blobMemory == 2)
        #expect(session.createdBlobs[0].payload.blobFlags == 1)
        #expect(session.createdBlobs[0].payload.blobID == 0)
        #expect(session.createdGlobalFenceIDs == [0x1_0000_00f1])
        #expect(session.createdFenceFlags == [0, 0])
        #expect(session.pollCallCount >= 3)
        #expect(session.invalidated == false)
    }

    @Test func surfaceLifecycleFailureFailsClosedBeforeAdvertisingVirGL2() throws {
        let session = FakeRendererForeignSession(rejectSurfaceSubmit: true)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.virgl2Context) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.submissions.count == 1)
        #expect(session.detachedResources.contains {
            $0 == (0xffff_fff0, 0xffff_fff5)
        })
        #expect(session.unreferencedResourceIDs.contains(0xffff_fff5))
        #expect(session.invalidated)
    }

    @Test func globalFenceABIFailureFailsClosedBeforeAdvertisingAcceleration() throws {
        let session = FakeRendererForeignSession(rejectGlobalFence: true)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.fenceExport) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.createdGlobalFenceIDs == [0x1_0000_00f1])
        #expect(session.createdFenceFlags.isEmpty)
        #expect(session.invalidated)
    }

    @Test func pipeBufferAllocationFailureFailsClosedBeforeAdvertisingVirGL2() throws {
        let session = FakeRendererForeignSession(rejectBufferResource: true)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.virgl2Context) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.createdResources3D.map(\.resourceID) == [0xffff_fff4])
        #expect(session.invalidated)
    }

    @Test func pipeBufferWidthCannotExceedAuthenticatedBootstrapByteLimit() throws {
        let limits = try DoryRendererWorkerLimits(
            maximumCommandBytes: DoryRendererWorkerLimits.production.maximumCommandBytes,
            maximumSharedRegions: DoryRendererWorkerLimits.production.maximumSharedRegions,
            maximumReferencedBytes: 1_024,
            maximumInFlightCommands: 8,
            maximumLiveScanoutLeases: 4,
            maximumScanoutBytes: 1_024
        )
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap(limits: limits))
        let oversizedBuffer = try DoryRendererResource3DCreatePayload(
            target: 0,
            format: 64,
            bind: 1 << 4,
            width: 2_048,
            height: 1,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 0
        )
        let preflightCreateCount = session.createdResources3D.count

        #expect(throws: DoryRendererForeignSessionError.self) {
            _ = try backend.execute(
                command: command(
                    requestID: 1,
                    operation: .createResource3D,
                    resourceID: 42,
                    payload: oversizedBuffer.encoded
                ),
                descriptors: []
            )
        }
        #expect(session.createdResources3D.count == preflightCreateCount)
        #expect(backend.snapshot().resourceCount == 0)
    }

    @Test func foreignRendererLifetimeUsesOnePersistentPthreadAcrossCallers() throws {
        let session = FakeRendererForeignSession(missingPollDescriptor: true)
        let backend = makeBackend(session: session)
        let callerThreads = ThreadIDRecorder()
        callerThreads.recordCurrent()

        _ = try backend.activate(bootstrap: makeBootstrap())
        let payload = try DoryRendererResource3DCreatePayload(
            target: 0,
            format: 64,
            bind: 1 << 4,
            width: 512,
            height: 1,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 0
        )
        let executeCommand = try command(
            requestID: 1,
            operation: .createResource3D,
            resourceID: 42,
            payload: payload.encoded
        )
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            callerThreads.recordCurrent()
            _ = try? backend.execute(command: executeCommand, descriptors: [])
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 2) == .success)

        let pollCountAfterActivation = session.pollCallCount
        let pollDeadline = ContinuousClock.now + .milliseconds(100)
        while session.pollCallCount == pollCountAfterActivation,
              ContinuousClock.now < pollDeadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
        _ = backend.snapshot()
        backend.invalidate()

        #expect(callerThreads.snapshot.count == 2)
        #expect(session.foreignThreadIDs.count == 1)
        #expect(session.foreignThreadIDs.isDisjoint(with: callerThreads.snapshot))
        #expect(session.pollCallCount > pollCountAfterActivation)
    }

    @Test func missingNativeSharedTextureFailsClosedBeforeAdvertisingVirGL2() throws {
        let session = FakeRendererForeignSession(rejectMetalTexture: true)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.virgl2Context) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.invalidated)
    }

    @Test func activationPumpsRendererWithoutAThreadSyncDescriptor() async throws {
        let session = FakeRendererForeignSession(missingPollDescriptor: true)
        let backend = makeBackend(session: session)

        let receipt = try backend.activate(bootstrap: makeBootstrap())
        #expect(receipt.productionAccelerationIsAdmissible)

        let deadline = ContinuousClock.now + .milliseconds(100)
        while session.pollCallCount < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(session.pollCallCount >= 3)
        backend.invalidate()
    }

    @Test func missingVirGL2CapabilityFailsClosedForTheProcessGeneration() throws {
        let session = FakeRendererForeignSession(missingVirGL2: true)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.virgl2Capability) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.invalidated)
    }

    @Test func missingVenusCapabilityFailsClosedForTheProcessGeneration() throws {
        let session = FakeRendererForeignSession(missingVenus: true)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.venusCapability) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.invalidated)
        #expect(try isRejected(backend.execute(
            command: createContextCommand(requestID: 1),
            descriptors: []
        )))
    }

    @Test func nonzeroVenusOuterVersionFailsClosedForTheProcessGeneration() throws {
        let session = FakeRendererForeignSession(venusMaximumVersion: 1)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.venusCapability) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.invalidated)
    }

    @Test func nonSHMBlobExportFailsClosedBeforeCapabilityAdvertisement() throws {
        let session = FakeRendererForeignSession(exportedBlobType: 1)
        let backend = makeBackend(session: session)

        #expect(throws: DoryRendererWorkerBackendActivationError.sharedMemoryExport) {
            _ = try backend.activate(bootstrap: makeBootstrap())
        }
        #expect(session.invalidated)
    }

    @Test func scanoutLeaseTransfersOnlyProducerCompleteSHM() throws {
        let session = FakeRendererForeignSession()
        let bootstrap = try makeBootstrap()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: bootstrap)

        try expectSuccess(backend.execute(
            command: createContextCommand(requestID: 1),
            descriptors: []
        ))

        let blob = try DoryRendererBlobCreatePayload(
            blobMemory: 2, // Exact virgl public ABI: VIRGL_RENDERER_BLOB_MEM_HOST3D.
            blobFlags: 3, // MAPPABLE | SHAREABLE.
            blobID: 99,
            size: 4_096
        )
        let createBlob = try command(
            requestID: 2,
            operation: .createBlob,
            contextID: 7,
            resourceID: 42,
            payload: blob.encoded
        )
        let createResult = try requireSuccess(backend.execute(
            command: createBlob,
            descriptors: []
        ))
        #expect(createResult.payload == Data([1, 0, 0, 0, 0, 0, 0, 0]))
        #expect(createResult.descriptors.isEmpty)
        try expectSuccess(backend.execute(
            command: command(
                requestID: 3,
                operation: .attachResource,
                contextID: 7,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        ))

        let acquire = try DoryRendererScanoutAcquirePayload(
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0
        )
        let acquireResult = try requireSuccess(backend.execute(
            command: command(
                requestID: 4,
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 1,
                payload: acquire.encoded
            ),
            descriptors: []
        ))
        #expect(acquireResult.descriptors.count == 1)
        let lease = try DoryRendererScanoutLeaseCodec.decode(acquireResult.payload)
        #expect(lease.workerGeneration == bootstrap.generation)
        #expect(lease.resourceID == 42)
        #expect(lease.resourceGeneration == 1)
        #expect(lease.sharedMemoryDescriptorIndex == 0)
        #expect(lease.synchronization == .managedGuestProducerCompleteFlush)
        #expect(lease.leaseByteCount == 1_024)
        #expect(lease.declaredFileSize == 4_096)
        try acquireResult.descriptors[0].close()

        let release = try command(
            requestID: 5,
            operation: .releaseScanoutLease,
            resourceID: 42,
            resourceGeneration: 1,
            payload: lease.releaseToken.commandPayload
        )
        try expectSuccess(backend.execute(command: release, descriptors: []))
        #expect(isRejected(try backend.execute(command: release, descriptors: [])))
    }

    @Test func classicVirGLScanoutExportsOnePrivateSharedMetalTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 64,
            height: 4,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let producerTexture = try #require(device.makeSharedTexture(descriptor: descriptor))
        let session = FakeRendererForeignSession(metalTexture: producerTexture)
        let bootstrap = try makeBootstrap()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: bootstrap)

        try expectSuccess(backend.execute(
            command: command(
                requestID: 1,
                operation: .createContext,
                contextID: 7,
                payload: DoryRendererContextCreatePayload(
                    capsetID: 2,
                    name: "test-virgl2"
                ).encoded
            ),
            descriptors: []
        ))
        let resource = try DoryRendererResource3DCreatePayload(
            target: 2,
            format: 1,
            bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SAMPLER_VIEW) |
                UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT),
            width: 64,
            height: 4,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 0
        )
        try expectSuccess(backend.execute(
            command: command(
                requestID: 2,
                operation: .createResource3D,
                resourceID: 42,
                payload: resource.encoded
            ),
            descriptors: []
        ))
        try expectSuccess(backend.execute(
            command: command(
                requestID: 3,
                operation: .attachResource,
                contextID: 7,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        ))
        let acquire = try DoryRendererScanoutAcquirePayload(
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0
        )
        let execution = try backend.execute(
            command: command(
                requestID: 4,
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 1,
                payload: acquire.encoded
            ),
            descriptors: []
        )
        guard case .success(let payload, let descriptors, let handle?) = execution else {
            Issue.record("expected a native shared-texture scanout lease")
            return
        }
        #expect(descriptors.isEmpty)
        let lease = try DoryRendererSharedTextureScanoutLeaseCodec.decode(payload)
        #expect(lease.workerGeneration == bootstrap.generation)
        #expect(lease.resourceID == 42)
        #expect(lease.resourceGeneration == 1)
        #expect(lease.pixelFormat == .bgra8Unorm)
        #expect(lease.width == 64)
        #expect(lease.height == 4)
        let imported = try #require(device.makeSharedTexture(handle: handle))
        #expect(imported.device === device)
        #expect(imported.storageMode == .private)
        #expect(imported.pixelFormat == .bgra8Unorm)
        #expect(imported.width == 64)
        #expect(imported.height == 4)

        try expectSuccess(backend.execute(
            command: command(
                requestID: 5,
                operation: .releaseScanoutLease,
                resourceID: 42,
                resourceGeneration: 1,
                payload: lease.releaseToken.commandPayload
            ),
            descriptors: []
        ))
        #expect(backend.snapshot().liveScanoutLeaseCount == 0)
    }

    @Test func classicVirGLScanoutAcceptsOnlyAlphaEquivalentXFormats() throws {
        let cases: [(resourceFormat: UInt32, transportFormat: UInt32,
                     pixelFormat: DoryRendererScanoutPixelFormat)] = [
            (2, 1, .bgra8Unorm),
            (68, 67, .rgba8Unorm),
        ]
        for value in cases {
            let resourceInfo = DoryRendererForeignResourceInfo(
                resourceID: 42,
                format: value.resourceFormat,
                width: 64,
                height: 4,
                flags: 0,
                stride: 256
            )
            let session = FakeRendererForeignSession(resourceInfo: resourceInfo)
            let backend = makeBackend(session: session)
            _ = try backend.activate(bootstrap: makeBootstrap())

            let resource = try DoryRendererResource3DCreatePayload(
                target: 2,
                format: value.resourceFormat,
                bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                    UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT),
                width: 64,
                height: 4,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 0
            )
            try expectSuccess(backend.execute(
                command: command(
                    requestID: 1,
                    operation: .createResource3D,
                    resourceID: 42,
                    payload: resource.encoded
                ),
                descriptors: []
            ))
            let acquire = try DoryRendererScanoutAcquirePayload(
                width: 64,
                height: 4,
                virglFormat: value.transportFormat,
                stride: 256,
                storageOffset: 0
            )
            let execution = try backend.execute(
                command: command(
                    requestID: 2,
                    operation: .acquireScanoutLease,
                    resourceID: 42,
                    resourceGeneration: 1,
                    payload: acquire.encoded
                ),
                descriptors: []
            )
            guard case .success(let payload, let descriptors, let handle?) = execution else {
                Issue.record("expected an alpha-equivalent native scanout texture")
                continue
            }
            #expect(descriptors.isEmpty)
            _ = handle
            let lease = try DoryRendererSharedTextureScanoutLeaseCodec.decode(payload)
            #expect(lease.pixelFormat == value.pixelFormat)
            #expect(session.acquiredScanoutResourceIDs.last == 42)

            try expectSuccess(backend.execute(
                command: command(
                    requestID: 3,
                    operation: .releaseScanoutLease,
                    resourceID: 42,
                    resourceGeneration: 1,
                    payload: lease.releaseToken.commandPayload
                ),
                descriptors: []
            ))
        }
    }

    @Test func classicVirGLScanoutRejectsCrossFamilyAndUnknownFormatAliases() throws {
        let cases: [(resourceFormat: UInt32, transportFormat: UInt32)] = [
            (2, 67),
            (68, 1),
            (3, 1),
        ]
        for value in cases {
            let resourceInfo = DoryRendererForeignResourceInfo(
                resourceID: 42,
                format: value.resourceFormat,
                width: 64,
                height: 4,
                flags: 0,
                stride: 256
            )
            let session = FakeRendererForeignSession(resourceInfo: resourceInfo)
            let backend = makeBackend(session: session)
            _ = try backend.activate(bootstrap: makeBootstrap())

            let resource = try DoryRendererResource3DCreatePayload(
                target: 2,
                format: value.resourceFormat,
                bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                    UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT),
                width: 64,
                height: 4,
                depth: 1,
                arraySize: 1,
                lastLevel: 0,
                samples: 0,
                flags: 0
            )
            try expectSuccess(backend.execute(
                command: command(
                    requestID: 1,
                    operation: .createResource3D,
                    resourceID: 42,
                    payload: resource.encoded
                ),
                descriptors: []
            ))
            let acquire = try DoryRendererScanoutAcquirePayload(
                width: 64,
                height: 4,
                virglFormat: value.transportFormat,
                stride: 256,
                storageOffset: 0
            )
            #expect(isRejected(try backend.execute(
                command: command(
                    requestID: 2,
                    operation: .acquireScanoutLease,
                    resourceID: 42,
                    resourceGeneration: 1,
                    payload: acquire.encoded
                ),
                descriptors: []
            )))
            #expect(!session.acquiredScanoutResourceIDs.contains(42))
            #expect(backend.snapshot().liveScanoutLeaseCount == 0)
        }
    }

    @Test func classicCreate2DScanoutDoesNotRequireVirGLContextAttachment() throws {
        let resourceInfo = DoryRendererForeignResourceInfo(
            resourceID: 42,
            format: 1,
            width: 64,
            height: 4,
            flags: 1,
            stride: 256
        )
        let session = FakeRendererForeignSession(resourceInfo: resourceInfo)
        let bootstrap = try makeBootstrap()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: bootstrap)

        let resource2D = try DoryRendererResource3DCreatePayload(
            target: 2,
            format: 1,
            bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT),
            width: 64,
            height: 4,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 1
        )
        try expectSuccess(backend.execute(
            command: command(
                requestID: 1,
                operation: .createResource3D,
                resourceID: 42,
                payload: resource2D.encoded
            ),
            descriptors: []
        ))
        let acquire = try DoryRendererScanoutAcquirePayload(
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0
        )
        let execution = try backend.execute(
            command: command(
                requestID: 2,
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 1,
                payload: acquire.encoded
            ),
            descriptors: []
        )
        guard case .success(let payload, let descriptors, let handle?) = execution else {
            Issue.record("expected a native dumb-KMS shared-texture scanout lease")
            return
        }
        #expect(descriptors.isEmpty)
        _ = handle
        let lease = try DoryRendererSharedTextureScanoutLeaseCodec.decode(payload)
        #expect(lease.resourceID == 42)
        #expect(lease.resourceGeneration == 1)
        #expect(lease.yOriginTop)
        #expect(session.attachedResources.allSatisfy { $0.1 != 42 })
        #expect(session.acquiredScanoutResourceIDs.last == 42)

        try expectSuccess(backend.execute(
            command: command(
                requestID: 3,
                operation: .releaseScanoutLease,
                resourceID: 42,
                resourceGeneration: 1,
                payload: lease.releaseToken.commandPayload
            ),
            descriptors: []
        ))
    }

    @Test func contextAttachAndDetachMatchVirglIdempotentResourceLifecycle() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        try expectSuccess(backend.execute(
            command: createContextCommand(requestID: 1),
            descriptors: []
        ))
        let payload = try DoryRendererBlobCreatePayload(
            blobMemory: 2,
            blobFlags: 1,
            blobID: 0,
            size: 4_096
        )
        let create = try requireSuccess(backend.execute(
            command: command(
                requestID: 2,
                operation: .createBlob,
                resourceID: 42,
                payload: payload.encoded
            ),
            descriptors: []
        ))
        #expect(create.payload == Data([1, 0, 0, 0, 0, 0, 0, 0]))

        for requestID in [UInt64(3), 4] {
            try expectSuccess(backend.execute(
                command: command(
                    requestID: requestID,
                    operation: .attachResource,
                    contextID: 7,
                    resourceID: 42,
                    resourceGeneration: 1
                ),
                descriptors: []
            ))
        }

        let userAttachments = session.attachedResources.filter { $0.1 == 42 }
        #expect(userAttachments.count == 1)
        #expect(userAttachments.first?.0 == 7)

        for requestID in [UInt64(5), 6] {
            try expectSuccess(backend.execute(
                command: command(
                    requestID: requestID,
                    operation: .detachResource,
                    contextID: 7,
                    resourceID: 42,
                    resourceGeneration: 1
                ),
                descriptors: []
            ))
        }
        let userDetachments = session.detachedResources.filter { $0.1 == 42 }
        #expect(userDetachments.count == 1)
        #expect(userDetachments.first?.0 == 7)
    }

    @Test func classicVirGLResourceWithoutScanoutBindCannotExportMetalTexture() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())

        try expectSuccess(backend.execute(
            command: command(
                requestID: 1,
                operation: .createContext,
                contextID: 7,
                payload: DoryRendererContextCreatePayload(
                    capsetID: 2,
                    name: "test-virgl2-no-scanout"
                ).encoded
            ),
            descriptors: []
        ))
        let resource = try DoryRendererResource3DCreatePayload(
            target: 2,
            format: 1,
            bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET) |
                UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_SAMPLER_VIEW),
            width: 64,
            height: 4,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 0
        )
        try expectSuccess(backend.execute(
            command: command(
                requestID: 2,
                operation: .createResource3D,
                resourceID: 42,
                payload: resource.encoded
            ),
            descriptors: []
        ))
        try expectSuccess(backend.execute(
            command: command(
                requestID: 3,
                operation: .attachResource,
                contextID: 7,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        ))
        let acquire = try DoryRendererScanoutAcquirePayload(
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0
        )
        #expect(try isRejected(backend.execute(
            command: command(
                requestID: 4,
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 1,
                payload: acquire.encoded
            ),
            descriptors: []
        )))
        #expect(session.acquiredScanoutResourceIDs == [0xffff_fff3])
    }

    @Test func scanoutLeaseUsesAuthenticatedLayoutWhenBlobResourceInfoIsEmpty() throws {
        let emptyBlobInfo = DoryRendererForeignResourceInfo(
            resourceID: 42,
            format: 0,
            width: 0,
            height: 0,
            flags: 0,
            stride: 0
        )
        let (execution, _) = try executeScanoutAcquire(
            resourceInfo: emptyBlobInfo,
            stride: 512
        )
        let success = try requireSuccess(execution)
        let lease = try DoryRendererScanoutLeaseCodec.decode(success.payload)
        #expect(lease.width == 64)
        #expect(lease.height == 4)
        #expect(lease.stride == 512)
        #expect(lease.storageOffset == 0)
        #expect(lease.leaseByteCount == 2_048)
        #expect(lease.yOriginTop)
        for descriptor in success.descriptors { try descriptor.close() }
    }

    @Test func scanoutRejectsMisalignedOrOutOfBoundsLayoutBeforeExport() throws {
        let invalid: [(stride: UInt32, offset: UInt32)] = [
            (255, 0),
            (260, 0),
            (256, 1),
            (512, 3_072),
            (0xffff_ff00, 0),
        ]
        for layout in invalid {
            let (execution, session) = try executeScanoutAcquire(
                stride: layout.stride,
                storageOffset: layout.offset
            )
            #expect(isRejected(execution))
            #expect(!session.exportedResourceIDs.contains(42))
        }
    }

    @Test func resetPermanentlyRevokesOldGenerationScanoutAcquisition() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        let reset = try DoryRendererResetPayload(successorGeneration: 10)
        try expectSuccess(backend.execute(
            command: command(
                requestID: 1,
                operation: .resetAfterDeviceQuiesce,
                payload: reset.encoded
            ),
            descriptors: []
        ))
        let acquire = try DoryRendererScanoutAcquirePayload(
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: 256,
            storageOffset: 0
        )
        #expect(isRejected(try backend.execute(
            command: command(
                requestID: 2,
                operation: .acquireScanoutLease,
                resourceID: 42,
                resourceGeneration: 1,
                payload: acquire.encoded
            ),
            descriptors: []
        )))
        #expect(!session.exportedResourceIDs.contains(42))
    }

    @Test func ordinaryContextFencesRemainOneShot() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        try expectSuccess(backend.execute(
            command: createContextCommand(requestID: 1),
            descriptors: []
        ))

        for offset in 0...4_096 {
            let fence = try DoryRendererFencePayload(
                flags: DoryRendererFencePayload.contextTimeline,
                ringIndex: 0,
                fenceID: UInt64(offset + 1)
            )
            let result = try requireSuccess(backend.execute(
                command: command(
                    requestID: UInt64(offset + 2),
                    operation: .createFence,
                    contextID: 7,
                    payload: fence.encoded
                ),
                descriptors: []
            ))
            #expect(result.descriptors.count == 1)
            try result.descriptors[0].close()
        }
        #expect(backend.snapshot().liveScanoutLeaseCount == 0)
    }

    @Test func globalFencePreservesFullGuestIdentityAndExportsOneShotReceipt() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        try expectSuccess(backend.execute(
            command: createContextCommand(requestID: 1),
            descriptors: []
        ))
        let guestFenceID = UInt64(UInt32.max) + 0x1234
        let fence = try DoryRendererFencePayload(
            flags: 0,
            ringIndex: 0,
            fenceID: guestFenceID
        )

        let result = try requireSuccess(backend.execute(
            command: command(
                requestID: 2,
                operation: .createFence,
                contextID: 7,
                payload: fence.encoded
            ),
            descriptors: []
        ))

        #expect(result.payload == fence.encoded)
        #expect(result.descriptors.count == 1)
        #expect(session.createdGlobalFenceIDs == [0x1_0000_00f1, guestFenceID])
        try result.descriptors[0].close()
    }

    @Test func globalFenceWithoutLiveSubmitContextIsRejectedBeforeForeignCall() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        let preflightGlobalFenceCount = session.createdGlobalFenceIDs.count
        let fence = try DoryRendererFencePayload(flags: 0, ringIndex: 0, fenceID: 91)

        #expect(try isRejected(backend.execute(
            command: command(
                requestID: 1,
                operation: .createFence,
                contextID: 7,
                payload: fence.encoded
            ),
            descriptors: []
        )))
        #expect(session.createdGlobalFenceIDs.count == preflightGlobalFenceCount)
    }

    @Test func wireContractRejectsMalformedGlobalFencePayload() {
        #expect(throws: DoryRendererWorkerContractError.self) {
            _ = try DoryRendererFencePayload(flags: 0, ringIndex: 1, fenceID: 1)
        }
    }

    @Test func unrefDetachesOwnedBackingBeforeUnrefAndPreservesSameIDReuse() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        let resource = try DoryRendererResource3DCreatePayload(
            target: 2,
            format: 1,
            bind: UInt32(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET),
            width: 4,
            height: 4,
            depth: 1,
            arraySize: 1,
            lastLevel: 0,
            samples: 0,
            flags: 0
        )
        try expectSuccess(backend.execute(
            command: command(
                requestID: 1,
                operation: .createResource3D,
                resourceID: 42,
                payload: resource.encoded
            ),
            descriptors: []
        ))

        let backingDescriptor = try FakeRendererForeignSession.makeAnonymousFile(
            byteCount: 4_096
        )
        var marker: UInt8 = 0x6d
        guard pwrite(backingDescriptor, &marker, 1, 0) == 1 else {
            close(backingDescriptor)
            throw POSIXError(.EIO)
        }
        let backingHandle = FileHandle(
            fileDescriptor: backingDescriptor,
            closeOnDealloc: true
        )
        let region = try DoryRendererSharedRegionReference(
            identity: .random(),
            descriptorIndex: 0,
            access: .readWrite,
            offset: 0,
            length: 4_096,
            declaredFileSize: 4_096
        )
        try expectSuccess(backend.execute(
            command: command(
                requestID: 2,
                operation: .attachBacking,
                resourceID: 42,
                resourceGeneration: 1,
                sharedRegions: [region]
            ),
            descriptors: [backingHandle]
        ))
        try backingHandle.close()

        try expectSuccess(backend.execute(
            command: command(
                requestID: 3,
                operation: .unrefResource,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        ))
        #expect(session.detachedBackings.last {
            $0.resourceID == 42
        }?.firstByte == marker)
        #expect(session.resourceLifecycleEvents.filter {
            $0.resourceID == 42
        } == [
            .attachBacking(42),
            .detachBacking(42),
            .unrefResource(42),
        ])

        let recreated = try requireSuccess(backend.execute(
            command: command(
                requestID: 4,
                operation: .createResource3D,
                resourceID: 42,
                payload: resource.encoded
            ),
            descriptors: []
        ))
        #expect(recreated.payload == Data([2, 0, 0, 0, 0, 0, 0, 0]))
        let lifecycleCount = session.resourceLifecycleEvents.count
        #expect(isRejected(try backend.execute(
            command: command(
                requestID: 5,
                operation: .unrefResource,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        )))
        #expect(session.resourceLifecycleEvents.count == lifecycleCount)

        try expectSuccess(backend.execute(
            command: command(
                requestID: 6,
                operation: .unrefResource,
                resourceID: 42,
                resourceGeneration: 2
            ),
            descriptors: []
        ))
        #expect(session.resourceLifecycleEvents.filter {
            $0.resourceID == 42
        } == [
            .attachBacking(42),
            .detachBacking(42),
            .unrefResource(42),
            .unrefResource(42),
        ])
        #expect(backend.snapshot().resourceCount == 0)
    }

    @Test func staleResourceGenerationCannotMapRecreatedResource() throws {
        let session = FakeRendererForeignSession()
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        try expectSuccess(backend.execute(
            command: createContextCommand(requestID: 1),
            descriptors: []
        ))
        let blob = try DoryRendererBlobCreatePayload(
            blobMemory: 2,
            blobFlags: 3,
            blobID: 100,
            size: 4_096
        )
        let create = try command(
            requestID: 2,
            operation: .createBlob,
            contextID: 7,
            resourceID: 42,
            payload: blob.encoded
        )
        try expectSuccess(backend.execute(command: create, descriptors: []))
        try expectSuccess(backend.execute(
            command: command(
                requestID: 3,
                operation: .unrefResource,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        ))
        let recreated = try requireSuccess(backend.execute(
            command: command(
                requestID: 4,
                operation: .createBlob,
                contextID: 7,
                resourceID: 42,
                payload: blob.encoded
            ),
            descriptors: []
        ))
        #expect(recreated.payload == Data([2, 0, 0, 0, 0, 0, 0, 0]))

        #expect(isRejected(try backend.execute(
            command: command(
                requestID: 5,
                operation: .mapBlob,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        )))
        #expect(session.exportedResourceIDs.last != 42)
    }

    private func makeBackend(
        session: FakeRendererForeignSession
    ) -> DoryRendererWorkerVirglBackend {
        DoryRendererWorkerVirglBackend(
            verifier: FakeRendererArtifactVerifier(),
            sessionFactory: FakeRendererForeignSessionFactory(session: session),
            alignmentProvider: FixedRendererAlignment(alignment: 256)
        )
    }

    private func executeScanoutAcquire(
        resourceInfo: DoryRendererForeignResourceInfo = DoryRendererForeignResourceInfo(
            resourceID: 42,
            format: 0,
            width: 0,
            height: 0,
            flags: 0,
            stride: 0
        ),
        stride: UInt32 = 256,
        storageOffset: UInt32 = 0
    ) throws -> (DoryRendererWorkerBackendExecution, FakeRendererForeignSession) {
        let session = FakeRendererForeignSession(resourceInfo: resourceInfo)
        let backend = makeBackend(session: session)
        _ = try backend.activate(bootstrap: makeBootstrap())
        try expectSuccess(backend.execute(
            command: createContextCommand(requestID: 1),
            descriptors: []
        ))
        let blob = try DoryRendererBlobCreatePayload(
            blobMemory: 2,
            blobFlags: 3,
            blobID: 99,
            size: 4_096
        )
        try expectSuccess(backend.execute(
            command: command(
                requestID: 2,
                operation: .createBlob,
                contextID: 7,
                resourceID: 42,
                payload: blob.encoded
            ),
            descriptors: []
        ))
        try expectSuccess(backend.execute(
            command: command(
                requestID: 3,
                operation: .attachResource,
                contextID: 7,
                resourceID: 42,
                resourceGeneration: 1
            ),
            descriptors: []
        ))
        let acquire = try DoryRendererScanoutAcquirePayload(
            width: 64,
            height: 4,
            virglFormat: 1,
            stride: stride,
            storageOffset: storageOffset
        )
        return (
            try backend.execute(
                command: command(
                    requestID: 4,
                    operation: .acquireScanoutLease,
                    resourceID: 42,
                    resourceGeneration: 1,
                    payload: acquire.encoded
                ),
                descriptors: []
            ),
            session
        )
    }

    private func makeBootstrap(
        limits: DoryRendererWorkerLimits = .production
    ) throws -> DoryRendererWorkerBootstrap {
        func digest(_ byte: UInt8) throws -> DoryRendererArtifactDigest {
            try DoryRendererArtifactDigest(bytes: Data(repeating: byte, count: 32))
        }
        return try DoryRendererWorkerBootstrap(
            workspaceID: .random(),
            generation: DoryRendererWorkerGeneration(rawValue: 9),
            sourceTuple: .productionCandidate,
            producerFenceContract: .managedLinux61230PrepareFBV1,
            requestedCapabilities: .productionAcceleration,
            artifacts: DoryRendererArtifactManifest(
                candidateInventory: digest(1),
                managedGuestKernel: digest(2),
                guestMesa: digest(3),
                rendererWorkerExecutable: digest(4),
                rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                    bytes: Data(repeating: 5, count: DoryCodeDirectoryHash.byteCount)
                )
            ),
            limits: limits
        )
    }

    private func createContextCommand(requestID: UInt64) throws -> DoryRendererWorkerCommand {
        try command(
            requestID: requestID,
            operation: .createContext,
            contextID: 7,
            payload: DoryRendererContextCreatePayload(
                capsetID: 4,
                name: "test-venus"
            ).encoded
        )
    }

    private func command(
        requestID: UInt64,
        operation: DoryRendererWorkerOperation,
        contextID: UInt32 = 0,
        resourceID: UInt32 = 0,
        resourceGeneration: UInt64 = 0,
        sharedRegions: [DoryRendererSharedRegionReference] = [],
        payload: Data = Data()
    ) throws -> DoryRendererWorkerCommand {
        try DoryRendererWorkerCommand(
            generation: DoryRendererWorkerGeneration(rawValue: 9),
            requestID: requestID,
            operation: operation,
            contextID: contextID,
            resourceID: resourceID,
            resourceGeneration: resourceGeneration,
            deadlineUptimeNanoseconds: 1,
            sharedRegions: sharedRegions,
            payload: payload
        )
    }

    private func requireSuccess(
        _ execution: DoryRendererWorkerBackendExecution
    ) throws -> (payload: Data, descriptors: [FileHandle]) {
        guard case .success(let payload, let descriptors, nil) = execution else {
            throw TestFailure.expectedSuccess
        }
        return (payload, descriptors)
    }

    private func expectSuccess(_ execution: DoryRendererWorkerBackendExecution) throws {
        _ = try requireSuccess(execution)
    }

    private func isRejected(_ execution: DoryRendererWorkerBackendExecution) -> Bool {
        if case .rejected = execution { return true }
        return false
    }
}

private enum TestFailure: Error {
    case expectedSuccess
}

private final class ThreadIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var threadIDs = Set<UInt64>()

    func recordCurrent() {
        var threadID: UInt64 = 0
        guard pthread_threadid_np(nil, &threadID) == 0 else { return }
        lock.withLock { _ = threadIDs.insert(threadID) }
    }

    var snapshot: Set<UInt64> {
        lock.withLock { threadIDs }
    }
}

private struct FakeRendererArtifactVerifier:
    DoryRendererProductionArtifactVerifying,
    Sendable
{
    func verify(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererArtifactAttestation {
        DoryRendererArtifactAttestation(
            candidateInventory: bootstrap.artifacts.candidateInventory,
            rendererWorkerExecutable: bootstrap.artifacts.rendererWorkerExecutable
        )
    }
}

private struct FakeRendererForeignSessionFactory:
    DoryRendererForeignSessionCreating,
    Sendable
{
    let session: FakeRendererForeignSession

    func create(
        attestation _: DoryRendererArtifactAttestation
    ) throws -> any DoryRendererForeignSession {
        session.recordForeignCallThread()
        return session
    }
}

private struct FixedRendererAlignment:
    DoryRendererScanoutAlignmentProviding,
    Sendable
{
    let alignment: UInt32

    func minimumLinearTextureAlignment(
        pixelFormat _: DoryRendererScanoutPixelFormat
    ) -> UInt32? {
        alignment
    }
}

private struct FakeBackingAttachment {
    let resourceID: UInt32
    let iovecCount: UInt32
    let firstLength: Int
    let firstByte: UInt8?
}

private struct FakeTransfer {
    let toHost: Bool
    let resourceID: UInt32
    let contextID: UInt32
    let payload: DoryRendererTransfer3DPayload
    let usedExplicitIOVecs: Bool
    let iovecCount: UInt32
}

private struct FakeBackingDetachment {
    let resourceID: UInt32
    let firstByte: UInt8?
}

private enum FakeResourceLifecycleEvent: Equatable {
    case attachBacking(UInt32)
    case detachBacking(UInt32)
    case unrefResource(UInt32)

    var resourceID: UInt32 {
        switch self {
        case .attachBacking(let resourceID),
             .detachBacking(let resourceID),
             .unrefResource(let resourceID):
            resourceID
        }
    }
}

private final class FakeRendererForeignSession:
    DoryRendererForeignSession,
    @unchecked Sendable
{
    private let missingVirGL2: Bool
    private let missingVenus: Bool
    private let venusMaximumVersion: UInt32
    private let exportedBlobType: UInt32
    private let reportedResourceInfo: DoryRendererForeignResourceInfo
    private let metalTexture: (any MTLTexture)?
    private let missingPollDescriptor: Bool
    private let rejectMetalTexture: Bool
    private let rejectBufferResource: Bool
    private let rejectGlobalFence: Bool
    private let rejectSurfaceSubmit: Bool
    private let foreignThreadRecorder = ThreadIDRecorder()
    private let pollCountLock = NSLock()
    private var storedPollCallCount = 0
    private var pollReadDescriptor: Int32 = -1
    private var pollWriteDescriptor: Int32 = -1
    private var blobSizes = [UInt32: UInt64]()
    private var attachedBackingBaseAddresses = [UInt32: UnsafeMutableRawPointer]()
    private(set) var createdContextCapsets = [UInt32: UInt32]()
    private(set) var createdContextHistory = [UInt32: UInt32]()
    private(set) var exportedResourceIDs = [UInt32]()
    private(set) var acquiredScanoutResourceIDs = [UInt32]()
    private(set) var createdFenceFlags = [UInt32]()
    private(set) var createdGlobalFenceIDs = [UInt64]()
    private(set) var createdBlobs = [DoryRendererForeignBlobCreate]()
    private(set) var createdResources3D = [DoryRendererForeignResource3DCreate]()
    private(set) var attachedBackings = [FakeBackingAttachment]()
    private(set) var detachedBackings = [FakeBackingDetachment]()
    private(set) var detachedBackingResourceIDs = [UInt32]()
    private(set) var resourceLifecycleEvents = [FakeResourceLifecycleEvent]()
    private(set) var transfers = [FakeTransfer]()
    private(set) var attachedResources = [(UInt32, UInt32)]()
    private(set) var detachedResources = [(UInt32, UInt32)]()
    private(set) var submissions = [(contextID: UInt32, dwords: [UInt32])]()
    private(set) var unreferencedResourceIDs = [UInt32]()
    private(set) var invalidated = false

    init(
        missingVirGL2: Bool = false,
        missingVenus: Bool = false,
        venusMaximumVersion: UInt32 = 0,
        exportedBlobType: UInt32 = 3,
        resourceInfo: DoryRendererForeignResourceInfo? = nil,
        metalTexture: (any MTLTexture)? = nil,
        missingPollDescriptor: Bool = false,
        rejectMetalTexture: Bool = false,
        rejectBufferResource: Bool = false,
        rejectGlobalFence: Bool = false,
        rejectSurfaceSubmit: Bool = false
    ) {
        self.missingVirGL2 = missingVirGL2
        self.missingVenus = missingVenus
        self.venusMaximumVersion = venusMaximumVersion
        self.exportedBlobType = exportedBlobType
        self.metalTexture = metalTexture
        self.missingPollDescriptor = missingPollDescriptor
        self.rejectMetalTexture = rejectMetalTexture
        self.rejectBufferResource = rejectBufferResource
        self.rejectGlobalFence = rejectGlobalFence
        self.rejectSurfaceSubmit = rejectSurfaceSubmit
        var pollDescriptors = [Int32](repeating: -1, count: 2)
        if pipe(&pollDescriptors) == 0 {
            pollReadDescriptor = pollDescriptors[0]
            pollWriteDescriptor = pollDescriptors[1]
            for descriptor in pollDescriptors {
                let flags = fcntl(descriptor, F_GETFD)
                if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
            }
        }
        self.reportedResourceInfo = resourceInfo ?? DoryRendererForeignResourceInfo(
            resourceID: 42,
            format: 1,
            width: 64,
            height: 4,
            flags: 0,
            stride: 256
        )
    }

    func recordForeignCallThread() {
        foreignThreadRecorder.recordCurrent()
    }

    var foreignThreadIDs: Set<UInt64> {
        foreignThreadRecorder.snapshot
    }

    func capset(id: UInt32) throws -> DoryRendererForeignCapset {
        recordForeignCallThread()
        if id == 2 && missingVirGL2 {
            throw FakeRendererForeignSessionError.missingVirGL2
        }
        if id == 4 && missingVenus {
            throw FakeRendererForeignSessionError.missingVenus
        }
        return DoryRendererForeignCapset(
            id: id,
            maximumVersion: id == 2 ? 2 : venusMaximumVersion,
            bytes: Data([UInt8(id), 1, 2, 3])
        )
    }

    func createContext(id: UInt32, capsetID: UInt32, name _: String) throws {
        recordForeignCallThread()
        createdContextCapsets[id] = capsetID
        createdContextHistory[id] = capsetID
    }

    func destroyContext(id: UInt32) {
        recordForeignCallThread()
        createdContextCapsets.removeValue(forKey: id)
    }

    func attachResource(contextID: UInt32, resourceID: UInt32) {
        recordForeignCallThread()
        attachedResources.append((contextID, resourceID))
    }

    func detachResource(contextID: UInt32, resourceID: UInt32) {
        recordForeignCallThread()
        detachedResources.append((contextID, resourceID))
    }

    func submit(contextID: UInt32, bytes: UnsafeRawPointer, dwordCount: UInt32) throws {
        recordForeignCallThread()
        let dwords = Array(UnsafeBufferPointer(
            start: bytes.assumingMemoryBound(to: UInt32.self),
            count: Int(dwordCount)
        ))
        submissions.append((contextID: contextID, dwords: dwords))
        if rejectSurfaceSubmit, dwords.first == 0x0005_0801 {
            throw FakeRendererForeignSessionError.surfaceSubmitRejected
        }
    }

    func createBlob(
        _ resource: DoryRendererForeignBlobCreate,
        iovecs _: UnsafePointer<iovec>?,
        iovecCount _: UInt32
    ) throws {
        recordForeignCallThread()
        createdBlobs.append(resource)
        blobSizes[resource.resourceID] = resource.payload.size
    }

    func createResource3D(_ resource: DoryRendererForeignResource3DCreate) throws {
        recordForeignCallThread()
        createdResources3D.append(resource)
        if rejectBufferResource, resource.payload.target == 0 {
            throw FakeRendererForeignSessionError.bufferAllocationRejected
        }
    }

    func attachBacking(
        resourceID: UInt32,
        iovecs: UnsafePointer<iovec>,
        iovecCount: UInt32
    ) throws {
        recordForeignCallThread()
        let first = iovecs.pointee
        attachedBackings.append(FakeBackingAttachment(
            resourceID: resourceID,
            iovecCount: iovecCount,
            firstLength: first.iov_len,
            firstByte: first.iov_base?.assumingMemoryBound(to: UInt8.self).pointee
        ))
        if let baseAddress = first.iov_base {
            attachedBackingBaseAddresses[resourceID] = baseAddress
        }
        resourceLifecycleEvents.append(.attachBacking(resourceID))
    }

    func detachBacking(resourceID: UInt32) {
        recordForeignCallThread()
        let firstByte = attachedBackingBaseAddresses.removeValue(forKey: resourceID)?
            .assumingMemoryBound(to: UInt8.self).pointee
        detachedBackings.append(FakeBackingDetachment(
            resourceID: resourceID,
            firstByte: firstByte
        ))
        detachedBackingResourceIDs.append(resourceID)
        resourceLifecycleEvents.append(.detachBacking(resourceID))
    }

    func unrefResource(id: UInt32) {
        recordForeignCallThread()
        unreferencedResourceIDs.append(id)
        resourceLifecycleEvents.append(.unrefResource(id))
        blobSizes.removeValue(forKey: id)
    }

    func mapInfo(resourceID _: UInt32) throws -> UInt32 {
        recordForeignCallThread()
        return 1
    }

    func exportBlob(resourceID: UInt32) throws -> DoryRendererForeignExportedBlob {
        recordForeignCallThread()
        exportedResourceIDs.append(resourceID)
        return DoryRendererForeignExportedBlob(
            type: exportedBlobType,
            ownedFileDescriptor: try Self.makeAnonymousFile(
                byteCount: blobSizes[resourceID] ?? UInt64(getpagesize())
            )
        )
    }

    func resourceInfo(resourceID: UInt32) throws -> DoryRendererForeignResourceInfo {
        recordForeignCallThread()
        return reportedResourceInfo
    }

    func acquireScanoutMetalTexture(
        resourceID: UInt32,
        width: UInt32,
        height: UInt32,
        virglFormat: UInt32,
        stride _: UInt32,
        offset _: UInt32
    ) throws -> any MTLTexture {
        recordForeignCallThread()
        acquiredScanoutResourceIDs.append(resourceID)
        if rejectMetalTexture {
            throw FakeRendererForeignSessionError.missingMetalTexture
        }
        if let metalTexture,
           metalTexture.width == Int(width),
           metalTexture.height == Int(height) {
            return metalTexture
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw FakeRendererForeignSessionError.missingMetalTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: virglFormat == 1 ? .bgra8Unorm : .rgba8Unorm,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeSharedTexture(descriptor: descriptor) else {
            throw FakeRendererForeignSessionError.missingMetalTexture
        }
        return texture
    }

    func transfer(
        toHost: Bool,
        resourceID: UInt32,
        contextID: UInt32,
        payload: DoryRendererTransfer3DPayload,
        iovecs: UnsafePointer<iovec>?,
        iovecCount: UInt32
    ) throws {
        recordForeignCallThread()
        transfers.append(FakeTransfer(
            toHost: toHost,
            resourceID: resourceID,
            contextID: contextID,
            payload: payload,
            usedExplicitIOVecs: iovecs != nil,
            iovecCount: iovecCount
        ))
    }

    func createFence(
        contextID _: UInt32,
        flags: UInt32,
        ringIndex _: UInt32,
        fenceID _: UInt64
    ) throws {
        recordForeignCallThread()
        createdFenceFlags.append(flags)
    }

    func createGlobalFence(fenceID: UInt64) throws {
        recordForeignCallThread()
        createdGlobalFenceIDs.append(fenceID)
        if rejectGlobalFence {
            throw FakeRendererForeignSessionError.globalFenceRejected
        }
    }

    func exportFence(fenceID _: UInt64) throws -> Int32 {
        recordForeignCallThread()
        // Model the C shim's one-shot callback pipe. A regular file such as /dev/null is not a
        // faithful substitute on Darwin because its poll semantics vary by descriptor type.
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                close(readDescriptor)
                close(writeDescriptor)
                throw POSIXError(.EIO)
            }
        }
        var completion: UInt8 = 1
        guard Darwin.write(writeDescriptor, &completion, 1) == 1 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw POSIXError(.EIO)
        }
        close(writeDescriptor)
        return readDescriptor
    }

    var pollCallCount: Int {
        pollCountLock.withLock { storedPollCallCount }
    }

    func pollDescriptor() throws -> Int32? {
        recordForeignCallThread()
        if missingPollDescriptor { return nil }
        guard pollReadDescriptor >= 0 else { throw POSIXError(.EMFILE) }
        return pollReadDescriptor
    }

    func poll() {
        recordForeignCallThread()
        pollCountLock.withLock { storedPollCallCount += 1 }
    }

    func invalidate() {
        recordForeignCallThread()
        if pollReadDescriptor >= 0 {
            close(pollReadDescriptor)
            pollReadDescriptor = -1
        }
        if pollWriteDescriptor >= 0 {
            close(pollWriteDescriptor)
            pollWriteDescriptor = -1
        }
        invalidated = true
    }

    deinit { invalidate() }

    fileprivate static func makeAnonymousFile(byteCount: UInt64) throws -> Int32 {
        var path = Array(
            (FileManager.default.temporaryDirectory.path
                + "/dory-renderer-shm-test.XXXXXX").utf8CString
        )
        let descriptor = path.withUnsafeMutableBufferPointer {
            mkstemp($0.baseAddress!)
        }
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        let unlinked = path.withUnsafeBufferPointer { unlink($0.baseAddress!) }
        guard unlinked == 0,
              byteCount <= UInt64(Int64.max),
              ftruncate(descriptor, off_t(byteCount)) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            close(descriptor)
            throw POSIXError(.EIO)
        }
        return descriptor
    }

}

private enum FakeRendererForeignSessionError: Error {
    case missingVirGL2
    case missingVenus
    case missingMetalTexture
    case bufferAllocationRejected
    case globalFenceRejected
    case surfaceSubmitRejected
}
