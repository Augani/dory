import Darwin
import DoryRendererWorkerContracts
import DoryVirtio
import Foundation
import Testing
@testable import DoryHV

@Suite struct DoryPCScanoutAccessLifetimeTests {
  @Test func scanoutUpdateConsumerMayRetireWithoutClosingItsActiveTransport() throws {
    let pipe = Pipe()
    let releases = Counter()
    let lease = try DoryRendererScanoutLease(
      workerGeneration: .init(rawValue: 7), resourceID: 42, resourceGeneration: 3,
      leaseID: .init(rawValue: UUID()), releaseToken: .init(rawValue: UUID()),
      sharedRegionID: .random(), sharedMemoryDescriptorIndex: 0,
      synchronization: .managedGuestProducerCompleteFlush, pixelFormat: .bgra8Unorm,
      yOriginTop: false, width: 64, height: 4, stride: 256, rowAlignment: 4,
      storageOffset: 0, declaredFileSize: 4_096, leaseByteCount: 1_024
    )
    let update = DoryPCVirGLScanoutUpdate(
      flush: .init(scanoutID: 0, resourceID: 42,
        sourceRectangle: .init(x: 0, y: 0, width: 64, height: 4),
        damagedRectangle: .init(x: 0, y: 0, width: 64, height: 4),
        resourceWidth: 64, resourceHeight: 4, virglFormat: 1, stride: 256, storageOffset: 0),
      scanout: .sharedMemory(.init(lease: lease, sharedMemoryDescriptor: pipe.fileHandleForReading)),
      release: { authority in
        releases.increment()
        authority.discardTransport()
      },
      isCurrentResource: { true }, isCurrentGeneration: { true }
    )
    try update.withSharedMemory { admitted, descriptor in
      #expect(admitted == lease)
      update.retire()
      #expect(releases.value == 0)
      #expect(fcntl(descriptor, F_GETFD) >= 0)
      #expect(throws: DoryPCVirGLRendererAuthorityError.rendererUnavailable) {
        try update.withSharedMemory { _, _ in Issue.record("retired update was admitted") }
      }
    }
    #expect(releases.value == 1)
    update.retire()
    #expect(releases.value == 1)
  }

  @Test func reentrantRetirementKeepsDescriptorAliveUntilConsumerUnwinds() throws {
    let pipe = Pipe()
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let releases = Counter()
    let lifetime = DoryPCScanoutAccessLifetime(value: descriptor) { _ in
      releases.increment()
      try? pipe.fileHandleForReading.close()
    }
    try lifetime.withValue { descriptor in
      lifetime.retire()
      lifetime.retire()
      #expect(!lifetime.isAdmitting)
      #expect(releases.value == 0)
      #expect(fcntl(descriptor, F_GETFD) >= 0)
      #expect(throws: DoryPCVirGLRendererAuthorityError.rendererUnavailable) {
        try lifetime.withValue { _ in Issue.record("retired consumer was admitted") }
      }
    }
    #expect(releases.value == 1)
    #expect(fcntl(descriptor, F_GETFD) == -1)
    lifetime.retire()
    #expect(releases.value == 1)
  }

  @Test func concurrentRetirementJoinsBothConsumerAndForeignRelease() throws {
    let consumerEntered = DispatchSemaphore(value: 0)
    let resumeConsumer = DispatchSemaphore(value: 0)
    let releaseEntered = DispatchSemaphore(value: 0)
    let resumeRelease = DispatchSemaphore(value: 0)
    let consumerFinished = DispatchSemaphore(value: 0)
    let callers = DispatchGroup()
    let finished = Counter()
    let releases = Counter()
    let lifetime = DoryPCScanoutAccessLifetime(value: 7) { _ in
      releases.increment()
      releaseEntered.signal()
      _ = resumeRelease.wait(timeout: .now() + 2)
    }
    defer { resumeConsumer.signal(); resumeRelease.signal() }
    DispatchQueue.global().async {
      try? lifetime.withValue { _ in
        consumerEntered.signal()
        _ = resumeConsumer.wait(timeout: .now() + 2)
      }
      consumerFinished.signal()
    }
    try #require(consumerEntered.wait(timeout: .now() + 2) == .success)
    for _ in 0..<4 {
      callers.enter()
      DispatchQueue.global().async {
        lifetime.retire()
        finished.increment()
        callers.leave()
      }
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while lifetime.isAdmitting && DispatchTime.now().uptimeNanoseconds < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    try #require(!lifetime.isAdmitting)
    #expect(finished.value == 0)
    #expect(releases.value == 0)
    resumeConsumer.signal()
    try #require(releaseEntered.wait(timeout: .now() + 2) == .success)
    #expect(finished.value == 0)
    #expect(callers.wait(timeout: .now() + 0.01) == .timedOut)
    resumeRelease.signal()
    try #require(callers.wait(timeout: .now() + 2) == .success)
    try #require(consumerFinished.wait(timeout: .now() + 2) == .success)
    #expect(finished.value == 4)
    #expect(releases.value == 1)
  }

  @Test func nestedAccessAndThrownBodyReleaseOnlyAfterOutermostConsumer() throws {
    enum Failure: Error { case expected }
    let releases = Counter()
    let lifetime = DoryPCScanoutAccessLifetime(value: 7) { _ in releases.increment() }
    #expect(throws: Failure.self) {
      try lifetime.withValue { _ in
        try lifetime.withValue { _ in
          lifetime.retire()
          #expect(releases.value == 0)
        }
        #expect(releases.value == 0)
        throw Failure.expected
      }
    }
    #expect(releases.value == 1)
    lifetime.retire()
    #expect(releases.value == 1)
  }

  @Test func retirementRevokesAQueuedConsumerWithoutReleasingTheActiveDescriptor() throws {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let secondAttempted = DispatchSemaphore(value: 0)
    let secondFinished = DispatchSemaphore(value: 0)
    let retirementFinished = DispatchSemaphore(value: 0)
    let releases = Counter()
    let secondEntered = Counter()
    let rejected = Counter()
    let lifetime = DoryPCScanoutAccessLifetime(value: 7) { _ in releases.increment() }
    defer { resume.signal() }
    DispatchQueue.global().async {
      try? lifetime.withValue { _ in
        entered.signal()
        _ = resume.wait(timeout: .now() + 2)
      }
      finished.signal()
    }
    try #require(entered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      secondAttempted.signal()
      do { try lifetime.withValue { _ in secondEntered.increment() } }
      catch { rejected.increment() }
      secondFinished.signal()
    }
    try #require(secondAttempted.wait(timeout: .now() + 2) == .success)
    #expect(secondFinished.wait(timeout: .now() + 0.01) == .timedOut)
    #expect(secondEntered.value == 0)
    DispatchQueue.global().async {
      lifetime.retire()
      retirementFinished.signal()
    }
    try #require(secondFinished.wait(timeout: .now() + 2) == .success)
    #expect(rejected.value == 1)
    #expect(releases.value == 0)
    #expect(retirementFinished.wait(timeout: .now()) == .timedOut)
    resume.signal()
    try #require(finished.wait(timeout: .now() + 2) == .success)
    try #require(retirementFinished.wait(timeout: .now() + 2) == .success)
    #expect(releases.value == 1)
  }

  @Test func releaseCallbackMayReenterRetirementWithoutSynthesizingAnotherRelease() {
    let box = LifetimeBox()
    let releases = Counter()
    let lifetime = DoryPCScanoutAccessLifetime(value: 7) { _ in
      releases.increment()
      box.value?.retire()
      #expect(box.value?.isAdmitting == false)
    }
    box.value = lifetime
    lifetime.retire()
    lifetime.retire()
    #expect(releases.value == 1)
  }

  @Test func deinitializationReleasesAnUnusedValueExactlyOnce() {
    let releases = Counter()
    var lifetime: DoryPCScanoutAccessLifetime<Int>? = .init(value: 7) { _ in releases.increment() }
    #expect(lifetime?.isAdmitting == true)
    lifetime = nil
    #expect(releases.value == 1)
  }

  private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
  }

  private final class LifetimeBox: @unchecked Sendable {
    weak var value: DoryPCScanoutAccessLifetime<Int>?
  }
}
