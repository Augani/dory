import Foundation
import Testing
@testable import DoryHV
@testable import dory_hv

@Suite struct DesktopScanoutResourceLifetimeTests {
    @Test func presentationRequiresItsTypedProducerCompletionBoundary() throws {
        let synchronization = RecordingTexturePresentationSynchronization()
        let presentation = VirtioGPUTexturePresentation(
            resourceID: 4,
            resourceGeneration: 5,
            texture: VirtioGPUTextureResource(
                textureID: 44,
                format: 1,
                width: 8,
                height: 8,
                yOriginTop: true
            ),
            synchronization: synchronization
        )

        #expect(synchronization.prepareCount == 0)
        try presentation.prepareConsumerForPresentation()
        #expect(synchronization.prepareCount == 1)
        #expect(synchronization.discardCount == 0)
    }

    @Test func rendererRetirementWaitsForEveryDistinctScanoutAcknowledgement() {
        let completion = LockedCounter()
        let release = VirtioGPUScanoutResourceRelease(
            resourceID: 12,
            resourceGeneration: 34,
            scanoutCount: 2,
            completion: { completion.increment() }
        )

        release.acknowledge(scanoutID: 0)
        release.acknowledge(scanoutID: 0)
        release.acknowledge(scanoutID: 9)
        #expect(completion.value == 0)

        release.acknowledge(scanoutID: 1)
        release.acknowledge(scanoutID: 1)
        #expect(completion.value == 1)
    }

    @Test func delayedReleaseCannotClearAReusedCPUResourceID() {
        var lifetime = DesktopScanoutResourceLifetime()
        let old = DesktopScanoutResourceIdentity(
            frame: Self.makeFrame(resourceID: 9, generation: 3)
        )
        let replacement = DesktopScanoutResourceIdentity(
            frame: Self.makeFrame(resourceID: 9, generation: 4)
        )

        let boundOld = lifetime.bind(old)
        let boundReplacement = lifetime.bind(replacement)
        let clearedByOldRelease = lifetime.release(resourceID: 9, throughGeneration: 3)
        #expect(boundOld)
        #expect(boundReplacement)
        #expect(!clearedByOldRelease)
        #expect(lifetime.boundIdentity == replacement)
        let reboundOld = lifetime.bind(old)
        #expect(!reboundOld)
    }

    @Test func copiedSurfaceBudgetsRejectMaximumGeometryAndGenerationChurnBeforeAllocation() {
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: 16,
            maximumAggregateSurfaceBytes: 24,
            maximumDrainBytes: 16
        )
        let maximumGeometry = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 1,
            resourceGeneration: 1,
            format: 1,
            width: .max,
            height: .max,
            stride: 4,
            dirtyRect: VirtioGPURect(x: 0, y: 0, width: 1, height: 1),
            bytes: Data([0, 0, 0, 255])
        )

        #expect(coalescer.appendOutcome(maximumGeometry) == .budgetExceeded)
        #expect(coalescer.residentSurfaceBytes == 0)

        #expect(coalescer.appendOutcome(Self.makeFrame(
            resourceID: 1,
            generation: 1,
            width: 2,
            height: 2
        )) == .accepted)
        #expect(coalescer.residentSurfaceBytes == 16)

        var rejectedEveryChurnedGeneration = true
        for generation in 2...4_096 {
            if coalescer.appendOutcome(Self.makeFrame(
                resourceID: UInt32(generation),
                generation: UInt64(generation),
                width: 2,
                height: 2
            )) != .budgetExceeded {
                rejectedEveryChurnedGeneration = false
            }
        }
        #expect(rejectedEveryChurnedGeneration)
        #expect(coalescer.residentSurfaceBytes == 16)

        #expect(coalescer.remove(resourceID: 1, throughGeneration: 1) == 1)
        #expect(coalescer.residentSurfaceBytes == 0)
        #expect(coalescer.appendOutcome(Self.makeFrame(
            resourceID: 2,
            generation: 2,
            width: 2,
            height: 2
        )) == .accepted)
        #expect(coalescer.residentSurfaceBytes == 16)
    }

    @Test func copiedFrameDrainAppliesAnExplicitInFlightByteCeiling() {
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: 16,
            maximumAggregateSurfaceBytes: 32,
            maximumDrainBytes: 16
        )
        #expect(coalescer.append(Self.makeFrame(
            resourceID: 1,
            generation: 1,
            width: 2,
            height: 2
        )))
        #expect(coalescer.append(Self.makeFrame(
            resourceID: 2,
            generation: 1,
            width: 2,
            height: 2
        )))

        let first = coalescer.drain()
        #expect(first.frames.count == 1)
        #expect(first.outputByteCount == 16)
        #expect(first.hasMorePendingFrames)
        let second = coalescer.drain()
        #expect(second.frames.count == 1)
        #expect(second.outputByteCount == 16)
        #expect(!second.hasMorePendingFrames)
    }

    @MainActor
    @Test func mailboxReportsCopiedFrameBudgetRejectionAsDropAndHealthTelemetry() {
        let mailbox = DesktopFrameMailbox(
            maximumCPUSurfaceBytes: 16,
            maximumAggregateCPUSurfaceBytes: 16,
            maximumInFlightCPUFrameBytes: 16
        )
        mailbox.submit(Self.makeFrame(
            resourceID: 1,
            generation: 1,
            width: 3,
            height: 2
        ))

        #expect(mailbox.metrics == DesktopFrameMailboxMetrics(
            presentedFrames: 0,
            droppedFrames: 1,
            budgetRejectedFrames: 1,
            receivedFrameBytes: 24,
            droppedFrameBytes: 24
        ))
    }

    @Test func singleDamageUpdateDrainsWithoutAnyMailboxCopyOrFullSurfaceAllocation() throws {
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: 64 * 64 * 4,
            maximumAggregateSurfaceBytes: 64 * 64 * 4,
            maximumDrainBytes: 64 * 64 * 4
        )
        let frame = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 71,
            resourceGeneration: 3,
            format: 1,
            width: 64,
            height: 64,
            stride: 4,
            dirtyRect: VirtioGPURect(x: 27, y: 39, width: 1, height: 1),
            bytes: Data([1, 2, 3, 255])
        )

        #expect(coalescer.appendOutcome(frame) == .accepted)
        #expect(coalescer.metrics == DesktopScanoutFrameCoalescer.Metrics(
            residentBytes: 4,
            peakResidentBytes: 4,
            pendingFrameDepth: 1,
            peakPendingFrameDepth: 1,
            stagingCopyBytes: 0
        ))

        let drain = coalescer.drain()
        let output = try #require(drain.frames.first)
        #expect(drain.frames.count == 1)
        #expect(drain.inputFrameCount == 1)
        #expect(drain.outputByteCount == 4)
        #expect(drain.copyByteCount == 0)
        #expect(output == frame)
        #expect(coalescer.metrics.residentBytes == 0)
        #expect(coalescer.metrics.pendingFrameDepth == 0)
    }

    @Test func distantDamageRemainsSparseInsteadOfUploadingItsBoundingSurface() throws {
        let fullSurfaceBytes = 128 * 128 * 4
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: fullSurfaceBytes,
            maximumAggregateSurfaceBytes: fullSurfaceBytes,
            maximumDrainBytes: fullSurfaceBytes
        )
        let first = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 72,
            resourceGeneration: 9,
            format: 1,
            width: 128,
            height: 128,
            stride: 4,
            dirtyRect: VirtioGPURect(x: 0, y: 0, width: 1, height: 1),
            bytes: Data([10, 11, 12, 255])
        )
        let last = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 72,
            resourceGeneration: 9,
            format: 1,
            width: 128,
            height: 128,
            stride: 4,
            dirtyRect: VirtioGPURect(x: 127, y: 127, width: 1, height: 1),
            bytes: Data([20, 21, 22, 255])
        )

        #expect(coalescer.append(first))
        #expect(coalescer.append(last))
        #expect(coalescer.metrics.residentBytes < fullSurfaceBytes)
        #expect(coalescer.metrics.stagingCopyBytes == 8)

        let drain = coalescer.drain()
        #expect(drain.inputFrameCount == 2)
        #expect(drain.outputByteCount == 8)
        #expect(drain.copyByteCount == 8)
        #expect(drain.frames.map(\.dirtyRect) == [first.dirtyRect, last.dirtyRect])
        #expect(drain.frames.map(\.bytes) == [first.bytes, last.bytes])
    }

    @Test func overlappingDamageKeepsLatestPixelsWithTightStrideAndOriginalOrientation() throws {
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: 16,
            maximumAggregateSurfaceBytes: 16,
            maximumDrainBytes: 16
        )
        let initial = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 73,
            resourceGeneration: 1,
            format: 1,
            width: 2,
            height: 2,
            stride: 8,
            dirtyRect: VirtioGPURect(x: 0, y: 0, width: 2, height: 2),
            bytes: Data([
                1, 0, 0, 255, 2, 0, 0, 255,
                3, 0, 0, 255, 4, 0, 0, 255,
            ])
        )
        let overwrite = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 73,
            resourceGeneration: 1,
            format: 1,
            width: 2,
            height: 2,
            stride: 4,
            dirtyRect: VirtioGPURect(x: 1, y: 0, width: 1, height: 2),
            bytes: Data([
                9, 0, 0, 255,
                8, 0, 0, 255,
            ])
        )

        #expect(coalescer.append(initial))
        #expect(coalescer.append(overwrite))
        let drain = coalescer.drain()
        let frame = try #require(drain.frames.first)
        #expect(drain.frames.count == 1)
        #expect(frame.dirtyRect == initial.dirtyRect)
        #expect(frame.stride == 8)
        #expect(Array(frame.bytes) == [
            1, 0, 0, 255, 9, 0, 0, 255,
            3, 0, 0, 255, 8, 0, 0, 255,
        ])
    }

    @Test func paddedProducerRowsAreNormalizedOnceWithoutChangingDamageCoordinates() throws {
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: 4 * 3 * 4,
            maximumAggregateSurfaceBytes: 4 * 3 * 4,
            maximumDrainBytes: 4 * 3 * 4
        )
        let padded = VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: 74,
            resourceGeneration: 2,
            format: 1,
            width: 4,
            height: 3,
            stride: 8,
            dirtyRect: VirtioGPURect(x: 2, y: 1, width: 1, height: 2),
            bytes: Data([
                1, 2, 3, 255, 90, 91, 92, 93,
                4, 5, 6, 255, 94, 95, 96, 97,
            ])
        )

        #expect(coalescer.append(padded))
        #expect(coalescer.metrics.residentBytes == 8)
        #expect(coalescer.metrics.stagingCopyBytes == 8)
        let drain = coalescer.drain()
        let frame = try #require(drain.frames.first)
        #expect(drain.copyByteCount == 0)
        #expect(frame.dirtyRect == padded.dirtyRect)
        #expect(frame.stride == 4)
        #expect(Array(frame.bytes) == [
            1, 2, 3, 255,
            4, 5, 6, 255,
        ])
    }

    @Test func discardAndDrainLifetimeReleaseDepthAndSharedBudgetExactly() throws {
        let budget = DesktopCPUPresentationBudget(maximumResidentBytes: 64)
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: 64,
            maximumAggregateSurfaceBytes: 64,
            maximumDrainBytes: 64,
            sharedBudget: budget
        )
        let frame = Self.makeFrame(resourceID: 75, generation: 1)

        #expect(coalescer.append(frame))
        #expect(budget.metrics.residentBytes == 4)
        #expect(coalescer.discardPendingOutcome() == DesktopScanoutFrameCoalescer.Removal(
            frameCount: 1,
            payloadByteCount: 4
        ))
        #expect(budget.metrics.residentBytes == 0)
        #expect(coalescer.metrics.pendingFrameDepth == 0)

        #expect(coalescer.append(frame))
        var drain: DesktopScanoutFrameCoalescer.Drain? = coalescer.drain()
        #expect(drain?.frames.count == 1)
        #expect(coalescer.metrics.residentBytes == 0)
        #expect(budget.metrics.residentBytes == 4)
        drain = nil
        #expect(budget.metrics.residentBytes == 0)
    }

    @Test func newerCoveringDamageSupersedesPendingPayloadWithoutAStagingCopy() throws {
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: 16,
            maximumAggregateSurfaceBytes: 16,
            maximumDrainBytes: 16
        )
        let first = Self.makeFrame(resourceID: 76, generation: 1)
        var replacement = first
        replacement.bytes = Data([7, 8, 9, 255])

        #expect(coalescer.append(first))
        #expect(coalescer.append(replacement))
        #expect(coalescer.metrics.residentBytes == 4)
        #expect(coalescer.metrics.pendingFrameDepth == 2)
        #expect(coalescer.metrics.stagingCopyBytes == 0)
        let drain = coalescer.drain()
        #expect(drain.frames.count == 1)
        #expect(drain.inputFrameCount == 2)
        #expect(drain.copyByteCount == 0)
        #expect(drain.frames.first?.bytes == replacement.bytes)
    }

    @Test func seededDamageSequenceMaterializesEveryLatestPixelOnceAndNoUntouchedHoles() {
        let width = 70
        let height = 67
        let fullSurfaceBytes = width * height * 4
        let coalescer = DesktopScanoutFrameCoalescer(
            maximumSurfaceBytes: fullSurfaceBytes,
            maximumAggregateSurfaceBytes: fullSurfaceBytes,
            maximumDrainBytes: fullSurfaceBytes
        )
        var expected = [UInt8](repeating: 0, count: fullSurfaceBytes)
        var touched = [Bool](repeating: false, count: width * height)
        var submittedPayloadBytes = 0
        var inputFrameCount = 0

        func submit(x: Int, y: Int, width damageWidth: Int, height damageHeight: Int) {
            inputFrameCount += 1
            var bytes = Data(capacity: damageWidth * damageHeight * 4)
            for localY in 0..<damageHeight {
                for localX in 0..<damageWidth {
                    let red = UInt8(truncatingIfNeeded: inputFrameCount)
                    let green = UInt8(truncatingIfNeeded: x + localX)
                    let blue = UInt8(truncatingIfNeeded: y + localY)
                    bytes.append(contentsOf: [red, green, blue, 255])
                    let pixel = (y + localY) * width + x + localX
                    touched[pixel] = true
                    expected.replaceSubrange(
                        pixel * 4..<(pixel * 4 + 4),
                        with: [red, green, blue, 255]
                    )
                }
            }
            submittedPayloadBytes += bytes.count
            #expect(coalescer.append(VirtioGPUScanoutFrame(
                scanoutID: 0,
                resourceID: 77,
                resourceGeneration: 5,
                format: 1,
                width: UInt32(width),
                height: UInt32(height),
                stride: UInt32(damageWidth * 4),
                dirtyRect: VirtioGPURect(
                    x: UInt32(x),
                    y: UInt32(y),
                    width: UInt32(damageWidth),
                    height: UInt32(damageHeight)
                ),
                bytes: bytes
            )))
        }

        // Force sparse mode across two host-page cells before exercising overlapping updates.
        submit(x: 0, y: 0, width: 1, height: 1)
        submit(x: width - 1, y: height - 1, width: 1, height: 1)
        var randomState: UInt64 = 0xD0_7A_5E_ED
        func nextRandom() -> UInt32 {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt32(truncatingIfNeeded: randomState >> 32)
        }
        for _ in 0..<254 {
            let x = Int(nextRandom()) % width
            let y = Int(nextRandom()) % height
            let damageWidth = min(1 + Int(nextRandom()) % 8, width - x)
            let damageHeight = min(1 + Int(nextRandom()) % 8, height - y)
            submit(x: x, y: y, width: damageWidth, height: damageHeight)
        }

        #expect(coalescer.metrics.pendingFrameDepth == UInt64(inputFrameCount))
        #expect(coalescer.metrics.residentBytes <= fullSurfaceBytes)
        #expect(coalescer.metrics.stagingCopyBytes == UInt64(submittedPayloadBytes))

        let drain = coalescer.drain()
        var materialized = [UInt8](repeating: 0, count: fullSurfaceBytes)
        var materializedPixels = [Bool](repeating: false, count: width * height)
        for frame in drain.frames {
            for localY in 0..<Int(frame.dirtyRect.height) {
                for localX in 0..<Int(frame.dirtyRect.width) {
                    let pixel = (Int(frame.dirtyRect.y) + localY) * width
                        + Int(frame.dirtyRect.x) + localX
                    #expect(touched[pixel])
                    #expect(!materializedPixels[pixel])
                    materializedPixels[pixel] = true
                    let sourceOffset = localY * Int(frame.stride) + localX * 4
                    materialized.replaceSubrange(
                        pixel * 4..<(pixel * 4 + 4),
                        with: frame.bytes[sourceOffset..<(sourceOffset + 4)]
                    )
                }
            }
        }

        #expect(materializedPixels == touched)
        for pixel in touched.indices where touched[pixel] {
            #expect(materialized[pixel * 4..<(pixel * 4 + 4)]
                == expected[pixel * 4..<(pixel * 4 + 4)])
        }
        let touchedByteCount = touched.filter { $0 }.count * 4
        #expect(drain.inputFrameCount == UInt64(inputFrameCount))
        #expect(drain.outputByteCount == touchedByteCount)
        #expect(drain.copyByteCount == touchedByteCount)
    }

    private static func makeFrame(
        resourceID: UInt32,
        generation: UInt64,
        width: UInt32 = 1,
        height: UInt32 = 1
    ) -> VirtioGPUScanoutFrame {
        let byteCount = Int(width) * Int(height) * 4
        return VirtioGPUScanoutFrame(
            scanoutID: 0,
            resourceID: resourceID,
            resourceGeneration: generation,
            format: 1,
            width: width,
            height: height,
            stride: width * 4,
            dirtyRect: VirtioGPURect(x: 0, y: 0, width: width, height: height),
            bytes: Data(repeating: 0, count: byteCount)
        )
    }

}

private final class RecordingTexturePresentationSynchronization:
    VirtioGPUTexturePresentationSynchronization,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var prepares = 0
    private var discards = 0

    func prepareConsumerForPresentation() throws {
        lock.withLock { prepares += 1 }
    }

    func discardWithoutPresentation() {
        lock.withLock { discards += 1 }
    }

    var prepareCount: Int { lock.withLock { prepares } }
    var discardCount: Int { lock.withLock { discards } }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
