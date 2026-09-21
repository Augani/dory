import DoryRendererWorkerWireContracts
import DoryVMDisplayWireContracts
import Foundation
import Testing

@Suite("App-owned VM display wire contract")
struct DoryVMDisplayFrameTests {
    @Test("shared-memory leases round-trip canonically without frame bytes")
    func sharedMemoryRoundTrip() throws {
        let lease = try memoryLease()
        let frame = try DoryVMDisplayFrame(
            machineID: "ubuntu-desktop",
            operationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            scanoutID: 0,
            sequence: 7,
            displayResourceGeneration: 9,
            transport: .sharedMemory,
            leasePayload: DoryRendererScanoutLeaseCodec.encode(lease),
            sourceRect: .init(x: 0, y: 0, width: 1_920, height: 1_080),
            dirtyRect: .init(x: 10, y: 20, width: 640, height: 480)
        )
        try frame.validate(descriptorCount: 1, hasSharedTextureHandle: false)
        let encoded = try DoryVMDisplayFrameCodec.encode(frame)
        #expect(try DoryVMDisplayFrameCodec.decode(encoded) == frame)
        #expect(try frame.leaseID == lease.leaseID)
        #expect(try frame.releaseToken == lease.releaseToken)
        #expect(!encoded.contains(Data(repeating: 0xA5, count: 32)))
    }

    @Test("transport authority is exact and mutually exclusive")
    func exactTransportAuthority() throws {
        let frame = try DoryVMDisplayFrame(
            machineID: "fedora42",
            operationID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            scanoutID: 1,
            sequence: 1,
            displayResourceGeneration: 1,
            transport: .sharedTexture,
            leasePayload: DoryRendererSharedTextureScanoutLeaseCodec.encode(try textureLease()),
            sourceRect: .init(x: 0, y: 0, width: 1_280, height: 720),
            dirtyRect: .init(x: 0, y: 0, width: 1_280, height: 720)
        )
        try frame.validate(descriptorCount: 0, hasSharedTextureHandle: true)
        #expect(throws: DoryVMDisplayWireError.invalidTransportAuthority) {
            try frame.validate(descriptorCount: 1, hasSharedTextureHandle: true)
        }
        #expect(throws: DoryVMDisplayWireError.invalidTransportAuthority) {
            try frame.validate(descriptorCount: 0, hasSharedTextureHandle: false)
        }
    }

    @Test("rectangles and canonical identity fail closed")
    func invalidGeometryAndIdentity() throws {
        let operationID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        #expect(throws: DoryVMDisplayWireError.invalidRectangle) {
            _ = try DoryVMDisplayFrame(
                machineID: "ubuntu",
                operationID: operationID,
                scanoutID: 0,
                sequence: 1,
                displayResourceGeneration: 1,
                transport: .sharedMemory,
                leasePayload: DoryRendererScanoutLeaseCodec.encode(try memoryLease()),
                sourceRect: .init(x: 1_900, y: 0, width: 40, height: 20),
                dirtyRect: .init(x: 0, y: 0, width: 1, height: 1)
            )
        }
        #expect(throws: DoryVMDisplayWireError.invalidMachineID) {
            _ = try DoryVMDisplayFrame(
                machineID: "../ubuntu",
                operationID: operationID,
                scanoutID: 0,
                sequence: 1,
                displayResourceGeneration: 1,
                transport: .sharedMemory,
                leasePayload: DoryRendererScanoutLeaseCodec.encode(try memoryLease()),
                sourceRect: .init(x: 0, y: 0, width: 1_920, height: 1_080),
                dirtyRect: .init(x: 0, y: 0, width: 1, height: 1)
            )
        }
    }

    @Test("input, resize, and topology commands round-trip with exact validation")
    func commandRoundTrip() throws {
        let operationID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let input = try DoryVMDisplayCommand.input(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 1,
            endpoint: .absolutePointer,
            events: [
                .init(type: 3, code: 0, value: 16_384),
                .init(type: 3, code: 1, value: 8_192),
                .init(type: 1, code: 272, value: 1),
            ]
        )
        let inputData = try DoryVMDisplayCommandCodec.encode(input)
        #expect(try DoryVMDisplayCommandCodec.decode(inputData) == input)

        let resize = try DoryVMDisplayCommand.resize(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 2,
            scanoutID: 0,
            width: 2_560,
            height: 1_440,
            physicalWidthMillimeters: 344,
            physicalHeightMillimeters: 194
        )
        let resizeData = try DoryVMDisplayCommandCodec.encode(resize)
        #expect(try DoryVMDisplayCommandCodec.decode(resizeData) == resize)

        let topology = try DoryVMDisplayCommand.topology(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 3,
            displays: [
                .init(
                    width: 2_560,
                    height: 1_440,
                    physicalWidthMillimeters: 344,
                    physicalHeightMillimeters: 194
                ),
                .init(
                    width: 1_920,
                    height: 1_080,
                    physicalWidthMillimeters: 310,
                    physicalHeightMillimeters: 175
                ),
            ]
        )
        let topologyData = try DoryVMDisplayCommandCodec.encode(topology)
        #expect(try DoryVMDisplayCommandCodec.decode(topologyData) == topology)

        let restart = try DoryVMDisplayCommand.restartGraphics(
            machineID: "ubuntu",
            operationID: operationID,
            sequence: 4
        )
        let restartData = try DoryVMDisplayCommandCodec.encode(restart)
        #expect(try DoryVMDisplayCommandCodec.decode(restartData) == restart)
    }

    @Test("commands reject cross-endpoint events and mixed payloads")
    func invalidCommands() throws {
        let operationID = UUID(uuidString: "a0000000-0000-0000-0000-00000000000a")!
        #expect(throws: DoryVMDisplayWireError.invalidCommand) {
            _ = try DoryVMDisplayCommand.input(
                machineID: "ubuntu",
                operationID: operationID,
                sequence: 1,
                endpoint: .keyboard,
                events: [.init(type: 3, code: 0, value: 1)]
            )
        }
        #expect(throws: DoryVMDisplayWireError.invalidCommand) {
            _ = try DoryVMDisplayCommand.topology(
                machineID: "ubuntu",
                operationID: operationID,
                sequence: 3,
                displays: []
            )
        }
        #expect(throws: DoryVMDisplayWireError.invalidCommand) {
            _ = try DoryVMDisplayCommand.resize(
                machineID: "ubuntu",
                operationID: operationID,
                sequence: 2,
                scanoutID: 0,
                width: 0,
                height: 1_080,
                physicalWidthMillimeters: 300,
                physicalHeightMillimeters: 200
            )
        }
    }

    @Test("cursor updates are canonical, bounded, and hide explicitly")
    func cursorRoundTrip() throws {
        let operationID = UUID(uuidString: "b0000000-0000-0000-0000-00000000000b")!
        let visible = try DoryVMDisplayCursor.visible(
            machineID: "ubuntu",
            operationID: operationID,
            scanoutID: 1,
            sequence: 3,
            resourceID: 9,
            x: 100,
            y: 200,
            width: 2,
            height: 2,
            hotX: 1,
            hotY: 1,
            bytes: Data(repeating: 0x7F, count: 16)
        )
        let encoded = try DoryVMDisplayCursorCodec.encode(visible)
        #expect(try DoryVMDisplayCursorCodec.decode(encoded) == visible)

        let hidden = try DoryVMDisplayCursor.hidden(
            machineID: "ubuntu",
            operationID: operationID,
            scanoutID: 0,
            sequence: 4
        )
        #expect(!hidden.visible && hidden.bytes.isEmpty)
        #expect(throws: DoryVMDisplayWireError.invalidCursor) {
            _ = try DoryVMDisplayCursor.visible(
                machineID: "ubuntu",
                operationID: operationID,
                scanoutID: 0,
                sequence: 5,
                resourceID: 1,
                x: 0,
                y: 0,
                width: 2,
                height: 2,
                hotX: 0,
                hotY: 0,
                bytes: Data(repeating: 0, count: 15)
            )
        }
    }

    private func memoryLease() throws -> DoryRendererScanoutLease {
        try DoryRendererScanoutLease(
            workerGeneration: DoryRendererWorkerGeneration(rawValue: 4),
            resourceID: 3,
            resourceGeneration: 5,
            leaseID: DoryRendererScanoutLeaseID(
                rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
            ),
            releaseToken: DoryRendererScanoutReleaseToken(
                rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
            ),
            sharedRegionID: DoryRendererSharedRegionID(
                rawValue: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!
            ),
            sharedMemoryDescriptorIndex: 0,
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .bgra8Unorm,
            yOriginTop: true,
            width: 1_920,
            height: 1_080,
            stride: 7_680,
            rowAlignment: 256,
            storageOffset: 0,
            declaredFileSize: 8_294_400,
            leaseByteCount: 8_294_400
        )
    }

    private func textureLease() throws -> DoryRendererSharedTextureScanoutLease {
        try DoryRendererSharedTextureScanoutLease(
            workerGeneration: DoryRendererWorkerGeneration(rawValue: 8),
            resourceID: 7,
            resourceGeneration: 6,
            leaseID: DoryRendererScanoutLeaseID(
                rawValue: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
            ),
            releaseToken: DoryRendererScanoutReleaseToken(
                rawValue: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
            ),
            synchronization: .managedGuestProducerCompleteFlush,
            pixelFormat: .rgba8Unorm,
            yOriginTop: false,
            width: 1_280,
            height: 720
        )
    }
}
