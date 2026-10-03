import Darwin
import Foundation

/// Revokes admission before joining consumers, without executing foreign code under a lock.
/// Re-entrant retirement cannot join its own consumer/release callback: that exact callback
/// retains the value and performs the release as it unwinds. Every other caller joins it.
final class DoryPCScanoutAccessLifetime<Value: Sendable>: @unchecked Sendable {
  private let lock = NSCondition()
  private let retirement = DispatchGroup()
  private var value: Value?
  private var release: (@Sendable (Value) -> Void)?
  private var accessesByThread: [UInt32: Int] = [:]
  private var retirementRequested = false
  private var releaseThread: UInt32?

  init(value: Value, release: @escaping @Sendable (Value) -> Void) {
    self.value = value
    self.release = release
    retirement.enter()
  }

  var isAdmitting: Bool { lock.withLock { !retirementRequested } }

  func withValue<Result>(_ body: (Value) throws -> Result) throws -> Result {
    let thread = pthread_mach_thread_np(pthread_self())
    let admitted = try lock.withLock { () throws -> Value in
      // Preserve serialized foreign consumer access to the shared descriptor/texture.
      // A nested access by its exact synchronous owner does not wait on itself.
      while !retirementRequested, !accessesByThread.isEmpty, accessesByThread[thread] == nil {
        lock.wait()
      }
      guard !retirementRequested, let value else {
        throw DoryPCVirGLRendererAuthorityError.rendererUnavailable
      }
      accessesByThread[thread, default: 0] += 1
      return value
    }
    defer { finishAccess(thread: thread) }
    return try body(admitted)
  }

  func retire() {
    let thread = pthread_mach_thread_np(pthread_self())
    let admission = lock.withLock { () -> (
      work: (Value, @Sendable (Value) -> Void)?, reentrant: Bool
    ) in
      retirementRequested = true
      lock.broadcast()
      let work = takeReleaseLocked(thread: thread)
      return (work, accessesByThread[thread] != nil || releaseThread == thread)
    }
    if let work = admission.work {
      completeRelease(work)
    } else if !admission.reentrant {
      // Closing admission is not a positive release receipt. Repeated and concurrent
      // callers wait until the exact consumer AND foreign release callback have ended.
      retirement.wait()
    }
  }

  private func finishAccess(thread: UInt32) {
    let work = lock.withLock { () -> (Value, @Sendable (Value) -> Void)? in
      let count = accessesByThread[thread]!
      if count == 1 { accessesByThread.removeValue(forKey: thread) }
      else { accessesByThread[thread] = count - 1 }
      lock.broadcast()
      return takeReleaseLocked(thread: thread)
    }
    if let work { completeRelease(work) }
  }

  /// The lifetime lock must be held. Moving the value and callback claims one exact release.
  private func takeReleaseLocked(thread: UInt32) -> (Value, @Sendable (Value) -> Void)? {
    guard retirementRequested, accessesByThread.isEmpty, let value, let release else {
      return nil
    }
    self.value = nil
    self.release = nil
    releaseThread = thread
    return (value, release)
  }

  private func completeRelease(_ work: (Value, @Sendable (Value) -> Void)) {
    work.1(work.0)
    lock.withLock { releaseThread = nil }
    retirement.leave()
  }

  deinit { retire() }
}
