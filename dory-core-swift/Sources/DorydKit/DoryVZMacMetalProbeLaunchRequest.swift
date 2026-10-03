import Darwin
import DoryOperations
import DoryVZMacCore
import Foundation

/// Explicit, one-shot diagnostic inputs for a daemon-managed Mac start. This is not a VM
/// configuration setting: it must travel with the exact start operation and must not persist as
/// a default for later boots or restores.
public struct DoryVZMacMetalProbeLaunchRequest: Sendable, Equatable {
  public let challengeURL: URL
  public let resultURL: URL

  public init(challengePath: String, resultPath: String) throws {
    func checkedURL(_ path: String) throws -> URL {
      guard path.hasPrefix("/"), !path.contains("\0") else {
        throw DoryVZMacMetalProbeLaunchError.invalidPath
      }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard url.path == path else { throw DoryVZMacMetalProbeLaunchError.invalidPath }
      return url
    }
    challengeURL = try checkedURL(challengePath)
    resultURL = try checkedURL(resultPath)
    guard challengeURL != resultURL,
      challengeURL.deletingLastPathComponent() == resultURL.deletingLastPathComponent()
    else {
      throw DoryVZMacMetalProbeLaunchError.invalidPath
    }
  }

  public func validate(
    machine: DoryMachineConfiguration,
    operationID: UUID
  ) throws {
    guard machine.guestFamily == .macOS,
      machine.guestArchitecture == .arm64,
      machine.bootMode == .macOSRestore,
      let bundlePath = machine.macOSMachineBundlePath
    else {
      throw DoryVZMacMetalProbeLaunchError.requiresMacGuest
    }
    let bundle = try DoryVZMacMachineBundle.load(
      from: URL(fileURLWithPath: bundlePath, isDirectory: true)
    )
    guard [.stopped, .suspended].contains(bundle.manifest.installationState) else {
      throw DoryVZMacMetalProbeLaunchError.requiresInstalledGuest
    }
    let challenge = try loadChallenge()
    guard challenge.machineID == bundle.manifest.machineIdentifierSHA256,
      challenge.operationID == DoryOperationIdentity.canonical(operationID)
    else {
      throw DoryVZMacMetalProbeLaunchError.challengeMismatch
    }
    var existing = stat()
    guard lstat(resultURL.path, &existing) != 0, errno == ENOENT,
      lstat(resultURL.appendingPathExtension("transport.json").path, &existing) != 0,
      errno == ENOENT
    else {
      throw DoryVZMacMetalProbeLaunchError.resultExists
    }
  }

  private func loadChallenge() throws -> DoryVZMacMetalProbeChallenge {
    let descriptor = open(challengeURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw DoryVZMacMetalProbeLaunchError.invalidChallengeFile
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_size > 0,
      status.st_size <= DoryVZMacMetalProbeTransport.maximumJSONBytes
    else {
      throw DoryVZMacMetalProbeLaunchError.invalidChallengeFile
    }
    var data = Data()
    let limit = DoryVZMacMetalProbeTransport.maximumJSONBytes
    var buffer = [UInt8](repeating: 0, count: min(limit + 1, 4096))
    while data.count <= limit {
      let count = read(descriptor, &buffer, min(buffer.count, limit + 1 - data.count))
      if count < 0 {
        if errno == EINTR { continue }
        throw DoryVZMacMetalProbeLaunchError.invalidChallengeFile
      }
      if count == 0 { break }
      data.append(contentsOf: buffer[..<count])
    }
    guard !data.isEmpty, data.count <= limit else {
      throw DoryVZMacMetalProbeLaunchError.invalidChallengeFile
    }
    let challenge = try JSONDecoder().decode(DoryVZMacMetalProbeChallenge.self, from: data)
    try challenge.validate()
    return challenge
  }
}

public enum DoryVZMacMetalProbeLaunchError: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case invalidPath
  case requiresMacGuest
  case requiresResolvedLaunch
  case requiresInstalledGuest
  case invalidChallengeFile
  case challengeMismatch
  case resultExists

  public var description: String {
    switch self {
    case .invalidPath:
      "Mac Metal probe challenge/result must be distinct absolute paths in the same directory"
    case .requiresMacGuest:
      "Mac Metal probe collection requires a native ARM64 macOS machine"
    case .requiresResolvedLaunch:
      "Mac Metal probe collection requires a daemon-resolved start operation"
    case .requiresInstalledGuest:
      "Mac Metal probe collection requires an installed stopped or suspended guest"
    case .invalidChallengeFile:
      "Mac Metal probe challenge must be a bounded regular file owned by this user"
    case .challengeMismatch:
      "Mac Metal probe challenge does not match the selected bundle and start operation"
    case .resultExists:
      "Mac Metal probe result or transport receipt already exists"
    }
  }
}
