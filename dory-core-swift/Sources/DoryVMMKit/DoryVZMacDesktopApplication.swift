import AppKit
import Darwin
import DoryCore
import DoryMacGuestIntegrationWire
import DoryOperations
import DoryVZMacCore
import DorydKit
import Foundation
import ImageIO
import SystemConfiguration

public enum DoryVZMacDesktopOperation: String, Sendable, Equatable {
  case install
  case run
  case resume
}

private enum DoryVZMacDesktopError: Error, CustomStringConvertible {
  case invalidGuestURL

  var description: String {
    switch self {
    case .invalidGuestURL: "Enter a valid HTTP or HTTPS address."
    }
  }
}

@MainActor
final class DoryVZMacDesktopInstallLifecycle {
  enum StopAction: Equatable { case cancelInstall, requestGuestShutdown, finish, waitForTransition }
  private enum Phase {
    case idle
    case installingRestore
    case startingFirstBoot
  }

  private var phase: Phase = .idle

  var isInstallingRestore: Bool { phase == .installingRestore }

  func stopAction(state: DoryVZMacAdapterState) -> StopAction {
    if isInstallingRestore || state == .prepared { return .cancelInstall }
    switch state {
    case .running: return .requestGuestShutdown
    case .stopped, .installFailed, .failed: return .finish
    default: return .waitForTransition
    }
  }

  func installThenStart(
    install: @MainActor () async throws -> Void,
    alreadyRunning: @MainActor () -> Bool = { false },
    start: @MainActor () async throws -> Void
  ) async throws {
    try Task.checkCancellation()
    guard phase == .idle else { throw DoryVZMacAdapterError.transitionInProgress }
    phase = .installingRestore
    do {
      try await install()
      try Task.checkCancellation()
      if !alreadyRunning() {
        phase = .startingFirstBoot
        try await start()
      }
      phase = .idle
    } catch {
      phase = .idle
      throw error
    }
  }

  func shouldFinishStoppedObservation(
    operation: DoryVZMacDesktopOperation
  ) -> Bool {
    !(operation == .install && phase == .installingRestore)
  }
}

public struct DoryVZMacDesktopArguments: Sendable, Equatable {
  public var operation: DoryVZMacDesktopOperation
  public var machineBundleURL: URL
  public var restoreImageURL: URL?
  public var guestToolsURL: URL?
  public var usbDiskURL: URL?
  public var usbDiskReadOnly: Bool
  /// Canonicalized directory roots from the daemon's pre-spawn share authority.
  public var shares: [DoryMachineShareConfiguration]
  public var devicePolicy: DoryVZMacDevicePolicy
  public var cameraDeviceUniqueID: String?
  public var restoreStateURL: URL?
  public var machineID: String?
  public var operationID: UUID?
  public var stateDirectoryURL: URL?
  public var controlSocketPath: String?
  public var handoffSocketPath: String?
  public var reconnectIdentity: DoryRuntimeReconnectLaunchIdentity?
  /// Only admitted for a managed host-only launch. The daemon resolves this path rather than
  /// allowing a guest definition to choose an executable.
  public var gvproxyPath: String?
  public var portForwards: [DoryVMPortForward]
  public var metalProbeChallengeURL: URL?
  public var metalProbeResultURL: URL?

  public init(
    operation: DoryVZMacDesktopOperation,
    machineBundleURL: URL,
    restoreImageURL: URL? = nil,
    guestToolsURL: URL? = nil,
    usbDiskURL: URL? = nil,
    usbDiskReadOnly: Bool = true,
    shares: [DoryMachineShareConfiguration] = [],
    devicePolicy: DoryVZMacDevicePolicy = .legacyDefault,
    cameraDeviceUniqueID: String? = nil,
    restoreStateURL: URL? = nil,
    machineID: String? = nil,
    operationID: UUID? = nil,
    stateDirectoryURL: URL? = nil,
    controlSocketPath: String? = nil,
    handoffSocketPath: String? = nil,
    reconnectIdentity: DoryRuntimeReconnectLaunchIdentity? = nil,
    gvproxyPath: String? = nil,
    portForwards: [DoryVMPortForward] = [],
    metalProbeChallengeURL: URL? = nil,
    metalProbeResultURL: URL? = nil
  ) {
    self.operation = operation
    self.machineBundleURL = machineBundleURL.standardizedFileURL
    self.restoreImageURL = restoreImageURL?.standardizedFileURL
    self.guestToolsURL = guestToolsURL?.standardizedFileURL
    self.usbDiskURL = usbDiskURL?.standardizedFileURL
    self.usbDiskReadOnly = usbDiskReadOnly
    self.shares = shares
    self.devicePolicy = devicePolicy
    self.cameraDeviceUniqueID = cameraDeviceUniqueID
    self.restoreStateURL = restoreStateURL?.standardizedFileURL
    self.machineID = machineID
    self.operationID = operationID
    self.stateDirectoryURL = stateDirectoryURL?.standardizedFileURL
    self.controlSocketPath = controlSocketPath
    self.handoffSocketPath = handoffSocketPath
    self.reconnectIdentity = reconnectIdentity
    self.gvproxyPath = gvproxyPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    self.portForwards = portForwards
    self.metalProbeChallengeURL = metalProbeChallengeURL?.standardizedFileURL
    self.metalProbeResultURL = metalProbeResultURL?.standardizedFileURL
  }

  public var hasManagedLifecycleContract: Bool {
    machineID != nil && operationID != nil && stateDirectoryURL != nil
      && controlSocketPath != nil && handoffSocketPath != nil
      && reconnectIdentity != nil
  }
}

public enum DoryVZMacDesktopArgumentError: Error, Sendable, Equatable, CustomStringConvertible {
  case missingOperation
  case unsupportedOperation(String)
  case missingValue(String)
  case duplicateArgument(String)
  case unknownArgument(String)
  case missingMachineBundle
  case restoreImageRequired
  case restoreImageUnexpected
  case restoreStateRequired
  case restoreStateUnexpected
  case usbReadOnlyWithoutDisk
  case pathMustBeAbsolute(String)
  case incompleteManagedLifecycleContract
  case invalidMachineID
  case invalidOperationID
  case invalidNetworkPolicy(String)
  case invalidClipboardPolicy
  case invalidBoolean(String, String)
  case invalidShare(String)
  case duplicateShareTag(String)
  case managedDirectoryShareMismatch
  case managedCameraGrantRequired
  case invalidCameraGrant
  case invalidCameraDeviceID
  case cameraDeviceWithoutBridge
  case hostOnlyNetworkRequiresManagedLifecycle
  case hostOnlyNetworkRequiresGVProxy
  case gvproxyUnexpected
  case invalidPortForwards
  case portForwardsRequireHostOnlyNetwork
  case incompleteMetalProbeContract
  case metalProbeRequiresRunningGuest
  case metalProbeOperationMismatch

  public var description: String {
    switch self {
    case .missingOperation: "missing VZMac operation"
    case .unsupportedOperation(let value): "unsupported VZMac operation: \(value)"
    case .missingValue(let flag): "missing value for \(flag)"
    case .duplicateArgument(let flag): "duplicate VZMac argument: \(flag)"
    case .unknownArgument(let flag): "unknown VZMac argument: \(flag)"
    case .missingMachineBundle: "--machine is required"
    case .restoreImageRequired: "--ipsw is required for VZMac installation"
    case .restoreImageUnexpected: "--ipsw is accepted only for VZMac installation"
    case .restoreStateRequired: "--restore-state is required for managed VZMac resume"
    case .restoreStateUnexpected: "--restore-state is accepted only for VZMac resume"
    case .usbReadOnlyWithoutDisk: "--usb-disk-read-only requires --usb-disk"
    case .pathMustBeAbsolute(let flag): "\(flag) must name an absolute path"
    case .incompleteManagedLifecycleContract:
      "managed VZMac launch requires machine, operation, state, control, and handoff identity"
    case .invalidMachineID: "--machine-id is not a safe machine identifier"
    case .invalidOperationID: "--operation-id is not a canonical UUID"
    case .invalidNetworkPolicy(let value):
      "unsupported VZMac network policy: \(value)"
    case .invalidClipboardPolicy:
      "VZMac clipboard transport and directional grants disagree"
    case .invalidBoolean(let flag, let value):
      "\(flag) must be true or false, not \(value)"
    case .invalidShare(let value):
      "invalid VZMac shared directory: \(value)"
    case .duplicateShareTag(let tag):
      "duplicate VZMac shared-directory tag: \(tag)"
    case .managedDirectoryShareMismatch:
      "managed VZMac directory-sharing policy does not match its authorized shares"
    case .managedCameraGrantRequired:
      "managed VZMac camera requires a selected host device and daemon-issued grant"
    case .invalidCameraGrant:
      "managed VZMac camera grant does not match this machine, operation, plan, and device"
    case .invalidCameraDeviceID:
      "--camera-device-id must name one bounded host capture device"
    case .cameraDeviceWithoutBridge:
      "--camera-device-id requires --camera true"
    case .hostOnlyNetworkRequiresManagedLifecycle:
      "VZMac host-only networking requires the daemon-managed lifecycle contract"
    case .hostOnlyNetworkRequiresGVProxy:
      "VZMac host-only networking requires a daemon-resolved gvproxy"
    case .gvproxyUnexpected:
      "--gvproxy is accepted only for VZMac host-only networking"
    case .invalidPortForwards:
      "--resolved-port-forwards is not a valid VZMac port-forward contract"
    case .portForwardsRequireHostOnlyNetwork:
      "VZMac port forwards require host-only networking"
    case .incompleteMetalProbeContract:
      "--metal-probe-challenge and --metal-probe-result must be supplied together"
    case .metalProbeRequiresRunningGuest:
      "Metal probe collection is accepted only for VZMac run or resume"
    case .metalProbeOperationMismatch:
      "Metal probe challenge operation ID does not match this managed launch"
    }
  }
}

public func parseDoryVZMacDesktopArguments(
  _ raw: [String]
) throws -> DoryVZMacDesktopArguments {
  guard let rawOperation = raw.first else {
    throw DoryVZMacDesktopArgumentError.missingOperation
  }
  guard let operation = DoryVZMacDesktopOperation(rawValue: rawOperation) else {
    throw DoryVZMacDesktopArgumentError.unsupportedOperation(rawOperation)
  }
  var values: [String: String] = [:]
  var shares = [DoryMachineShareConfiguration]()
  let usbDiskReadOnly = true
  var sawUSBReadOnlyFlag = false
  var index = 1
  while index < raw.count {
    let flag = raw[index]
    if flag == "--usb-disk-read-only" {
      guard !sawUSBReadOnlyFlag else {
        throw DoryVZMacDesktopArgumentError.duplicateArgument(flag)
      }
      sawUSBReadOnlyFlag = true
      index += 1
      continue
    }
    if flag == "--share" {
      guard index + 1 < raw.count else {
        throw DoryVZMacDesktopArgumentError.missingValue(flag)
      }
      let rawShare = raw[index + 1]
      do {
        shares.append(try DoryMachineShareConfiguration(argument: rawShare))
      } catch {
        throw DoryVZMacDesktopArgumentError.invalidShare(rawShare)
      }
      index += 2
      continue
    }
    guard
      [
        "--machine", "--ipsw", "--guest-tools", "--usb-disk", "--machine-id",
        "--operation-id", "--state-dir", "--control-sock", "--handoff-sock",
        "--restore-state", "--network", "--audio-input", "--audio-output", "--clipboard",
        "--spice-clipboard", "--clipboard-text-read", "--clipboard-text-write",
        "--clipboard-image-read", "--clipboard-image-write",
        "--directory-sharing", "--camera", "--camera-device-id", "--camera-grant", "--gvproxy",
        "--resolved-port-forwards",
        "--metal-probe-challenge", "--metal-probe-result",
        DoryRuntimeReconnectContract.fileDescriptorArgument,
      ].contains(flag)
    else {
      throw DoryVZMacDesktopArgumentError.unknownArgument(flag)
    }
    guard values[flag] == nil else {
      throw DoryVZMacDesktopArgumentError.duplicateArgument(flag)
    }
    guard index + 1 < raw.count else {
      throw DoryVZMacDesktopArgumentError.missingValue(flag)
    }
    values[flag] = raw[index + 1]
    index += 2
  }

  guard let machinePath = values["--machine"] else {
    throw DoryVZMacDesktopArgumentError.missingMachineBundle
  }
  let machineURL = try absoluteFileURL(machinePath, flag: "--machine", isDirectory: true)
  let restoreURL = try values["--ipsw"].map {
    try absoluteFileURL($0, flag: "--ipsw", isDirectory: false)
  }
  if operation == .install, restoreURL == nil {
    throw DoryVZMacDesktopArgumentError.restoreImageRequired
  }
  if operation != .install, restoreURL != nil {
    throw DoryVZMacDesktopArgumentError.restoreImageUnexpected
  }
  let restoreStateURL = try values["--restore-state"].map {
    try absoluteFileURL($0, flag: "--restore-state", isDirectory: false)
  }
  if operation != .resume, restoreStateURL != nil {
    throw DoryVZMacDesktopArgumentError.restoreStateUnexpected
  }
  let toolsURL = try values["--guest-tools"].map {
    try absoluteFileURL($0, flag: "--guest-tools", isDirectory: true)
  }
  let usbURL = try values["--usb-disk"].map {
    try absoluteFileURL($0, flag: "--usb-disk", isDirectory: false)
  }
  if sawUSBReadOnlyFlag, usbURL == nil {
    throw DoryVZMacDesktopArgumentError.usbReadOnlyWithoutDisk
  }
  let networkPolicy: DoryVZMacNetworkPolicy
  if let rawNetwork = values["--network"] {
    guard let parsed = DoryVZMacNetworkPolicy(rawValue: rawNetwork) else {
      throw DoryVZMacDesktopArgumentError.invalidNetworkPolicy(rawNetwork)
    }
    networkPolicy = parsed
  } else {
    networkPolicy = .sharedNAT
  }
  let managedLifecycleFlagPresent = [
    "--machine-id",
    "--operation-id",
    "--state-dir",
    "--control-sock",
    "--handoff-sock",
    DoryRuntimeReconnectContract.fileDescriptorArgument,
  ].contains { values[$0] != nil }
  let cameraBridgeEnabled = try parseOptionalBoolean(
    values["--camera"],
    flag: "--camera",
    defaultValue: managedLifecycleFlagPresent ? false : true
  )
  let cameraDeviceUniqueID = values["--camera-device-id"]
  if let cameraDeviceUniqueID {
    guard !cameraDeviceUniqueID.isEmpty,
      cameraDeviceUniqueID.utf8.count <= 512,
      cameraDeviceUniqueID.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f })
    else { throw DoryVZMacDesktopArgumentError.invalidCameraDeviceID }
    guard cameraBridgeEnabled else {
      throw DoryVZMacDesktopArgumentError.cameraDeviceWithoutBridge
    }
  }
  let clipboardEnabled = try parseOptionalBoolean(
    values["--clipboard"], flag: "--clipboard", defaultValue: true
  )
  let spiceClipboardEnabled = try parseOptionalBoolean(
    values["--spice-clipboard"], flag: "--spice-clipboard",
    defaultValue: clipboardEnabled
  )
  let clipboardTextReadEnabled = try parseOptionalBoolean(
    values["--clipboard-text-read"], flag: "--clipboard-text-read",
    defaultValue: clipboardEnabled
  )
  let clipboardTextWriteEnabled = try parseOptionalBoolean(
    values["--clipboard-text-write"], flag: "--clipboard-text-write",
    defaultValue: clipboardEnabled
  )
  let clipboardImageReadEnabled = try parseOptionalBoolean(
    values["--clipboard-image-read"], flag: "--clipboard-image-read",
    defaultValue: spiceClipboardEnabled
  )
  let clipboardImageWriteEnabled = try parseOptionalBoolean(
    values["--clipboard-image-write"], flag: "--clipboard-image-write",
    defaultValue: spiceClipboardEnabled
  )
  let anyClipboardDirection = spiceClipboardEnabled || clipboardTextReadEnabled
    || clipboardTextWriteEnabled || clipboardImageReadEnabled || clipboardImageWriteEnabled
  guard clipboardEnabled == anyClipboardDirection,
    !spiceClipboardEnabled || (clipboardTextReadEnabled && clipboardTextWriteEnabled
      && clipboardImageReadEnabled && clipboardImageWriteEnabled)
  else { throw DoryVZMacDesktopArgumentError.invalidClipboardPolicy }
  let devicePolicy = DoryVZMacDevicePolicy(
    network: networkPolicy,
    audio: DoryVZMacAudioPolicy(
      inputEnabled: try parseOptionalBoolean(
        values["--audio-input"],
        flag: "--audio-input",
        defaultValue: true
      ),
      outputEnabled: try parseOptionalBoolean(
        values["--audio-output"],
        flag: "--audio-output",
        defaultValue: true
      )
    ),
    clipboardEnabled: clipboardEnabled,
    spiceClipboardEnabled: spiceClipboardEnabled,
    clipboardTextReadEnabled: clipboardTextReadEnabled,
    clipboardTextWriteEnabled: clipboardTextWriteEnabled,
    clipboardImageReadEnabled: clipboardImageReadEnabled,
    clipboardImageWriteEnabled: clipboardImageWriteEnabled,
    directorySharingEnabled: try parseOptionalBoolean(
      values["--directory-sharing"],
      flag: "--directory-sharing",
      defaultValue: true
    ),
    cameraBridgeEnabled: cameraBridgeEnabled
  )
  var shareTags = Set<String>()
  for share in shares {
    guard shareTags.insert(share.tag).inserted else {
      throw DoryVZMacDesktopArgumentError.duplicateShareTag(share.tag)
    }
  }
  if managedLifecycleFlagPresent,
    values["--directory-sharing"] != nil,
    devicePolicy.directorySharingEnabled != !shares.isEmpty
  {
    throw DoryVZMacDesktopArgumentError.managedDirectoryShareMismatch
  }
  let machineID = values["--machine-id"]
  if let machineID,
    machineID.isEmpty || machineID.utf8.count > 63
      || !machineID.utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (65...90).contains(byte)
          || (97...122).contains(byte) || byte == 45 || byte == 95
      })
  {
    throw DoryVZMacDesktopArgumentError.invalidMachineID
  }
  let operationID: UUID?
  if let rawOperationID = values["--operation-id"] {
    guard let parsed = DoryOperationIdentity.parseCanonical(rawOperationID) else {
      throw DoryVZMacDesktopArgumentError.invalidOperationID
    }
    operationID = parsed
  } else {
    operationID = nil
  }
  let stateDirectoryURL = try values["--state-dir"].map {
    try absoluteFileURL($0, flag: "--state-dir", isDirectory: true)
  }
  let controlSocketPath = try values["--control-sock"].map {
    try absoluteFileURL($0, flag: "--control-sock", isDirectory: false).path
  }
  let handoffSocketPath = try values["--handoff-sock"].map {
    try absoluteFileURL($0, flag: "--handoff-sock", isDirectory: false).path
  }
  let reconnectIdentity = try values[DoryRuntimeReconnectContract.fileDescriptorArgument].map {
    guard let descriptor = Int32($0),
      descriptor == DoryRuntimeReconnectContract.childFileDescriptor
    else {
      throw DoryVZMacDesktopArgumentError.invalidOperationID
    }
    return try DoryRuntimeReconnectLaunchIdentity.decode(fileDescriptor: descriptor)
  }
  let managedValuesPresent = [
    machineID != nil,
    operationID != nil,
    stateDirectoryURL != nil,
    controlSocketPath != nil,
    handoffSocketPath != nil,
    reconnectIdentity != nil,
  ]
  guard
    managedValuesPresent.allSatisfy({ $0 })
      || managedValuesPresent.allSatisfy({ !$0 })
  else {
    throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
  }
  let gvproxyPath = try values["--gvproxy"].map {
    try absoluteFileURL($0, flag: "--gvproxy", isDirectory: false).path
  }
  let portForwards: [DoryVMPortForward]
  if let rawPortForwards = values["--resolved-port-forwards"] {
    do {
      portForwards = try JSONDecoder().decode(
        [DoryVMPortForward].self,
        from: Data(rawPortForwards.utf8)
      )
    } catch {
      throw DoryVZMacDesktopArgumentError.invalidPortForwards
    }
  } else {
    portForwards = []
  }
  if networkPolicy == .isolated {
    guard managedValuesPresent.allSatisfy({ $0 }) else {
      throw DoryVZMacDesktopArgumentError.hostOnlyNetworkRequiresManagedLifecycle
    }
    guard gvproxyPath != nil else {
      throw DoryVZMacDesktopArgumentError.hostOnlyNetworkRequiresGVProxy
    }
  } else if gvproxyPath != nil {
    throw DoryVZMacDesktopArgumentError.gvproxyUnexpected
  }
  if !portForwards.isEmpty, networkPolicy != .isolated {
    throw DoryVZMacDesktopArgumentError.portForwardsRequireHostOnlyNetwork
  }
  if let reconnectIdentity {
    guard reconnectIdentity.machineID == machineID,
      reconnectIdentity.operationID
        == operationID.map(DoryOperationIdentity.canonical)
    else {
      throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
    }
  }
  let cameraGrant = values["--camera-grant"]
  if managedValuesPresent.allSatisfy({ $0 }), cameraBridgeEnabled {
    guard let cameraDeviceUniqueID, let cameraGrant,
      let reconnectIdentity else {
      throw DoryVZMacDesktopArgumentError.managedCameraGrantRequired
    }
    guard reconnectIdentity.verifiesCameraGrant(
      cameraGrant, deviceUniqueID: cameraDeviceUniqueID
    ) else {
      throw DoryVZMacDesktopArgumentError.invalidCameraGrant
    }
  } else if cameraGrant != nil || (managedLifecycleFlagPresent && cameraDeviceUniqueID != nil) {
    throw DoryVZMacDesktopArgumentError.invalidCameraGrant
  }
  if let restoreStateURL {
    guard managedValuesPresent.allSatisfy({ $0 }), let stateDirectoryURL else {
      throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
    }
    try validateManagedRestoreStateURL(
      restoreStateURL,
      stateDirectoryURL: stateDirectoryURL
    )
  }
  if managedValuesPresent.allSatisfy({ $0 }), operation == .resume,
    restoreStateURL == nil
  {
    throw DoryVZMacDesktopArgumentError.restoreStateRequired
  }
  let metalProbeChallengeURL = try values["--metal-probe-challenge"].map {
    try absoluteFileURL($0, flag: "--metal-probe-challenge", isDirectory: false)
  }
  let metalProbeResultURL = try values["--metal-probe-result"].map {
    try absoluteFileURL($0, flag: "--metal-probe-result", isDirectory: false)
  }
  guard (metalProbeChallengeURL == nil) == (metalProbeResultURL == nil) else {
    throw DoryVZMacDesktopArgumentError.incompleteMetalProbeContract
  }
  if metalProbeChallengeURL != nil, operation == .install {
    throw DoryVZMacDesktopArgumentError.metalProbeRequiresRunningGuest
  }
  if let metalProbeChallengeURL, let operationID {
    let challenge = try JSONDecoder().decode(
      DoryVZMacMetalProbeChallenge.self,
      from: Data(contentsOf: metalProbeChallengeURL)
    )
    try challenge.validate()
    guard challenge.operationID == DoryOperationIdentity.canonical(operationID) else {
      throw DoryVZMacDesktopArgumentError.metalProbeOperationMismatch
    }
  }
  return DoryVZMacDesktopArguments(
    operation: operation,
    machineBundleURL: machineURL,
    restoreImageURL: restoreURL,
    guestToolsURL: toolsURL,
    usbDiskURL: usbURL,
    usbDiskReadOnly: usbDiskReadOnly,
    shares: shares,
    devicePolicy: devicePolicy,
    cameraDeviceUniqueID: cameraDeviceUniqueID,
    restoreStateURL: restoreStateURL,
    machineID: machineID,
    operationID: operationID,
    stateDirectoryURL: stateDirectoryURL,
    controlSocketPath: controlSocketPath,
    handoffSocketPath: handoffSocketPath,
    reconnectIdentity: reconnectIdentity,
    gvproxyPath: gvproxyPath,
    portForwards: portForwards,
    metalProbeChallengeURL: metalProbeChallengeURL,
    metalProbeResultURL: metalProbeResultURL
  )
}

private func parseOptionalBoolean(
  _ value: String?,
  flag: String,
  defaultValue: Bool
) throws -> Bool {
  guard let value else { return defaultValue }
  switch value {
  case "true": return true
  case "false": return false
  default: throw DoryVZMacDesktopArgumentError.invalidBoolean(flag, value)
  }
}

private enum DoryVZMacManagedSavedStateLeaf {
  case temporaryState
  case publishedState
}

private func validateManagedRestoreStateURL(
  _ stateURL: URL,
  stateDirectoryURL: URL
) throws {
  try validateManagedSavedStatePathShape(
    stateURL,
    stateDirectoryURL: stateDirectoryURL,
    expectedLeaf: .publishedState
  )
  try validateManagedSavedStateParent(
    stateDirectoryURL: stateDirectoryURL,
    leafName: stateURL.lastPathComponent,
    mustExist: true
  )
}

private func validateManagedSavedStatePathShape(
  _ stateURL: URL,
  stateDirectoryURL: URL,
  expectedLeaf: DoryVZMacManagedSavedStateLeaf
) throws {
  let root = stateDirectoryURL.standardizedFileURL
  let savedStateRoot = root.appendingPathComponent(
    DoryMachineSavedStateStore.directoryName,
    isDirectory: true
  )
  guard stateURL.deletingLastPathComponent().path == savedStateRoot.path else {
    throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute("--restore-state")
  }
  switch expectedLeaf {
  case .temporaryState:
    guard isCanonicalSavedStateTemporaryName(stateURL.lastPathComponent) else {
      throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute("--restore-state")
    }
  case .publishedState:
    guard stateURL.lastPathComponent == DoryMachineSavedStateManifest.stateFileName else {
      throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute("--restore-state")
    }
  }
}

private func validateManagedSavedStateParent(
  stateDirectoryURL: URL,
  leafName: String,
  mustExist: Bool
) throws {
  let root = try DoryTrustedDirectoryRoot(
    canonicalAbsolutePath: stateDirectoryURL.standardizedFileURL.path
  )
  let savedStateRoot = try root.openPrivateChildDirectory(
    DoryTrustedPathComponent(validating: DoryMachineSavedStateStore.directoryName)
  )
  try savedStateRoot.withBorrowedDescriptor { descriptor in
    let leaf = try DoryTrustedPathComponent(validating: leafName)
    let opened = openat(
      descriptor,
      leaf.value,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    if mustExist {
      guard opened >= 0 else { throw POSIXError(.ENOENT) }
      defer { close(opened) }
      try validateManagedSavedStateOpenFile(opened)
    } else if opened >= 0 {
      close(opened)
      throw DoryVZMacSavedStateError.destinationExists(leaf.value)
    } else if errno != ENOENT {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}

private func validateManagedSavedStateOpenFile(_ descriptor: Int32) throws {
  var status = stat()
  guard fstat(descriptor, &status) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  guard (status.st_mode & S_IFMT) == S_IFREG,
    status.st_uid == geteuid(),
    status.st_nlink == 1,
    (status.st_mode & 0o077) == 0,
    status.st_size > 0
  else {
    throw DoryVZMacSavedStateError.invalidArtifact("managed saved-state payload is not private")
  }
}

private func isCanonicalSavedStateTemporaryName(_ name: String) -> Bool {
  guard name.hasPrefix(DoryMachineSavedStateStore.temporaryStatePrefix) else { return false }
  let suffix = String(name.dropFirst(DoryMachineSavedStateStore.temporaryStatePrefix.count))
  guard suffix == suffix.lowercased(), UUID(uuidString: suffix) != nil else { return false }
  return suffix.count == 36
}

private func absoluteFileURL(
  _ path: String,
  flag: String,
  isDirectory: Bool
) throws -> URL {
  guard path.hasPrefix("/"), !path.contains("\0") else {
    throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute(flag)
  }
  let url = URL(fileURLWithPath: path, isDirectory: isDirectory).standardizedFileURL
  guard url.path == path || url.path + (isDirectory ? "/" : "") == path else {
    throw DoryVZMacDesktopArgumentError.pathMustBeAbsolute(flag)
  }
  return url
}

/// Entry point used by the signed, LaunchServices-started DoryVMM application for native macOS.
/// The main Dory process never owns a VZ virtual machine; closing a console requests guest power
/// off while this isolated process retains the VM, its lease, and its display until teardown.
public enum DoryVZMacDesktopMain {
  @MainActor
  public static func run(_ rawArguments: [String]) -> Int32 {
    do {
      let arguments = try parseDoryVZMacDesktopArguments(rawArguments)
      let application = NSApplication.shared
      let controller = try DoryVZMacDesktopApplication(
        application: application,
        arguments: arguments
      )
      return try controller.run()
    } catch {
      FileHandle.standardError.write(Data("dory-vmm VZMac: \(error)\n".utf8))
      return 2
    }
  }
}

@MainActor
private final class DoryVZMacDesktopApplication: NSObject, NSApplicationDelegate,
  NSWindowDelegate, NSMenuItemValidation
{
  private let application: NSApplication
  private let arguments: DoryVZMacDesktopArguments
  private let adapter: DoryVZMacAdapter
  private let window: NSWindow
  private var terminalError: Error?
  private var stopRequested = false
  private var guestStopIssued = false
  private var didFinish = false
  private var lifecycleTask: Task<Void, Never>?
  private var installCancellationPromptVisible = false
  private var controlServer: DoryVZMacControlServer?
  private var handoffPublished = false
  private let installLifecycle = DoryVZMacDesktopInstallLifecycle()
  private var lifecycleTrace: DoryVZMacLifecycleTraceRecorder?
  private var sleepObserver: NSObjectProtocol?
  private var wakeObserver: NSObjectProtocol?
  private var clipboardSessionObserver: NSObjectProtocol?
  private let clipboardActions = DoryVZMacClipboardActionAuthority()
  private var clipboardTask: Task<Void, Never>?
  private var clipboardDeadlineTask: Task<Void, Never>?
  private var signalSources: [DispatchSourceSignal] = []
  private var previousSignalHandlers: [(Int32, sig_t)] = []

  init(application: NSApplication, arguments: DoryVZMacDesktopArguments) throws {
    self.application = application
    self.arguments = arguments
    adapter = try DoryVZMacAdapter(
      configuration: DoryVZMacAdapterConfiguration(
        machineBundleURL: arguments.machineBundleURL,
        guestToolsURL: arguments.guestToolsURL,
        usbDiskURL: arguments.usbDiskURL,
        usbDiskReadOnly: arguments.usbDiskReadOnly,
        shares: arguments.shares,
        devicePolicy: arguments.devicePolicy,
        cameraDeviceUniqueID: arguments.cameraDeviceUniqueID,
        gvproxyPath: arguments.gvproxyPath,
        networkStateDirectoryURL: arguments.stateDirectoryURL,
        portForwards: arguments.portForwards,
        metalProbeChallengeURL: arguments.metalProbeChallengeURL,
        metalProbeResultURL: arguments.metalProbeResultURL,
        metalProbeExpectedOperationID: arguments.operationID.map(DoryOperationIdentity.canonical)
      )
    ) { message in
      FileHandle.standardError.write(Data("dory-vmm VZMac: \(message)\n".utf8))
    }
    let contentSize = NSSize(width: 1_280, height: 800)
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = adapter.displayView
    window.minSize = NSSize(width: 640, height: 400)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.tabbingMode = .disallowed
    window.center()
    super.init()
    window.delegate = self
    if arguments.hasManagedLifecycleContract,
      let machineID = arguments.machineID,
      let operationID = arguments.operationID,
      let stateDirectoryURL = arguments.stateDirectoryURL
    {
      do {
        let trace = try DoryVZMacLifecycleTraceRecorder(
          stateDirectoryURL: stateDirectoryURL,
          machineID: machineID,
          operationID: operationID,
          launchOperation: arguments.operation
        )
        lifecycleTrace = trace
        FileHandle.standardError.write(Data("dory-vmm VZMac lifecycle trace: \(trace.path)\n".utf8))
      } catch {
        // Evidence acquisition is fail-closed at qualification, but loss of its trace must not
        // prevent an otherwise valid user VM from running or recovering its disk.
        FileHandle.standardError.write(Data("dory-vmm VZMac lifecycle trace unavailable: \(error)\n".utf8))
      }
    }
    adapter.onObservation = { [weak self] observation in
      self?.observe(observation)
    }
  }

  func run() throws -> Int32 {
    DoryDesktopApplicationIdentity.install(on: application)
    application.setActivationPolicy(.regular)
    application.delegate = self
    setWindowTitle(initialTitle)
    window.makeKeyAndOrderFront(nil)
    application.activate()
    installViewMenu()
    installTerminationSignalHandlers()
    defer { cancelTerminationSignalHandlers() }
    lifecycleTrace?.record(.launchStarted)
    let workspaceNotifications = NSWorkspace.shared.notificationCenter
    sleepObserver = workspaceNotifications.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.revokeClipboardActions()
        self?.lifecycleTrace?.record(.hostWillSleep)
      }
    }
    wakeObserver = workspaceNotifications.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.lifecycleTrace?.record(.hostWoke) }
    }
    clipboardSessionObserver = workspaceNotifications.addObserver(
      forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.revokeClipboardActions() }
    }
    lifecycleTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { lifecycleTask = nil }
      do {
        try Task.checkCancellation()
        switch arguments.operation {
        case .install:
          guard let restoreImageURL = arguments.restoreImageURL else {
            throw DoryVZMacDesktopArgumentError.restoreImageRequired
          }
          guard let operationID = arguments.operationID else {
            throw DoryVZMacDesktopArgumentError.incompleteManagedLifecycleContract
          }
          try await installLifecycle.installThenStart {
            try await adapter.install(
              from: restoreImageURL,
              operationID: operationID
            ) { [weak self] fraction in
              self?.setWindowTitle(
                "\(self?.machineName ?? "macOS") — Installing macOS \(Int(fraction * 100))%"
              )
            }
          } alreadyRunning: {
            adapter.observation.state == .running
          } start: {
            try await adapter.start()
          }
        case .run:
          try await adapter.start()
        case .resume:
          try await adapter.restoreSuspendedState(from: arguments.restoreStateURL)
          lifecycleTrace?.record(.restoreCompleted)
        }
      } catch {
        terminalError = error
        finish()
      }
    }
    if stopRequested { lifecycleTask?.cancel() }
    application.run()
    lifecycleTrace?.close()
    if let terminalError { throw terminalError }
    return 0
  }

  private var machineName: String {
    arguments.machineBundleURL.deletingPathExtension().lastPathComponent
  }

  private var initialTitle: String {
    switch arguments.operation {
    case .install: "\(machineName) — Preparing macOS installation"
    case .run: "\(machineName) — Starting macOS"
    case .resume: "\(machineName) — Resuming macOS"
    }
  }

  private func setWindowTitle(_ title: String) {
    if let challenge = adapter.metalProbeChallenge {
      window.title = "\(title) — [\(challenge.productWindowTitleToken)]"
    } else {
      window.title = title
    }
  }

  private func observe(_ observation: DoryVZMacAdapterObservation) {
    guard !didFinish else { return }
    if observation.state != .running { revokeClipboardActions() }
    switch observation.state {
    case .installing:
      break
    case .starting:
      setWindowTitle("\(machineName) — Starting macOS")
    case .running:
      lifecycleTrace?.record(.running)
      setWindowTitle("\(machineName) — macOS")
      if stopRequested { applyStopRequest() }
      else { publishManagedReadyIfNeeded() }
    case .pausing:
      setWindowTitle("\(machineName) — Pausing macOS")
    case .paused:
      setWindowTitle("\(machineName) — macOS paused")
    case .suspending:
      setWindowTitle("\(machineName) — Suspending macOS")
    case .suspended:
      lifecycleTrace?.record(.suspended)
      setWindowTitle("\(machineName) — macOS suspended")
      if !arguments.hasManagedLifecycleContract {
        finish()
      }
    case .restoring:
      setWindowTitle("\(machineName) — Restoring macOS")
    case .stopping:
      setWindowTitle("\(machineName) — Shutting down macOS")
    case .stopped:
      lifecycleTrace?.record(.stopped)
      if installLifecycle.shouldFinishStoppedObservation(operation: arguments.operation) {
        finish()
      } else {
        setWindowTitle("\(machineName) — Starting macOS")
      }
    case .installFailed, .failed:
      lifecycleTrace?.record(.failed)
      terminalError = NSError(
        domain: "DoryVZMacDesktop",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: observation.failure ?? "macOS VM failed"]
      )
      finish()
    case .prepared:
      break
    }
  }

  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    revokeClipboardActions()
    cancelTerminationSignalHandlers()
    let workspaceNotifications = NSWorkspace.shared.notificationCenter
    if let sleepObserver { workspaceNotifications.removeObserver(sleepObserver) }
    if let wakeObserver { workspaceNotifications.removeObserver(wakeObserver) }
    if let clipboardSessionObserver { workspaceNotifications.removeObserver(clipboardSessionObserver) }
    sleepObserver = nil
    wakeObserver = nil
    clipboardSessionObserver = nil
    lifecycleTrace?.record(.processEnded)
    lifecycleTrace?.close()
    controlServer?.stop()
    controlServer = nil
    adapter.stopHostOnlyNetwork()
    application.stop(nil)
    if let event = NSEvent.otherEvent(
      with: .applicationDefined,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      subtype: 0,
      data1: 0,
      data2: 0
    ) {
      application.postEvent(event, atStart: false)
    }
  }

  private func requestStop() {
    guard !stopRequested, !didFinish else { return }
    stopRequested = true
    revokeClipboardActions()
    applyStopRequest()
  }

  private func applyStopRequest() {
    switch installLifecycle.stopAction(state: adapter.observation.state) {
    case .cancelInstall:
      setWindowTitle("\(machineName) — Cancelling macOS installation")
      lifecycleTask?.cancel()
    case .requestGuestShutdown:
      guard !guestStopIssued else { return }
      guestStopIssued = true
      do {
        try adapter.requestStop()
      } catch {
        terminalError = error
        finish()
      }
    case .finish:
      finish()
    case .waitForTransition:
      // A SIGTERM during first-boot start is remembered, then applied to the running guest.
      // Never call VZ stop/pause while Apple's installer or start transition owns the VM.
      break
    }
  }

  private func installTerminationSignalHandlers() {
    guard signalSources.isEmpty else { return }
    signalSources = [SIGTERM, SIGINT].map { signalNumber in
      if let previous = signal(signalNumber, SIG_IGN) {
        previousSignalHandlers.append((signalNumber, previous))
      }
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler { [weak self] in
        Task { @MainActor [weak self] in self?.requestStop() }
      }
      source.resume()
      return source
    }
  }

  private func cancelTerminationSignalHandlers() {
    let sources = signalSources
    let handlers = previousSignalHandlers
    signalSources = []
    previousSignalHandlers = []
    sources.forEach { $0.cancel() }
    handlers.forEach { signalNumber, handler in _ = signal(signalNumber, handler) }
  }

  private func publishManagedReadyIfNeeded() {
    guard !handoffPublished, arguments.hasManagedLifecycleContract,
      let machineID = arguments.machineID,
      let operationID = arguments.operationID,
      let stateDirectoryURL = arguments.stateDirectoryURL,
      let controlSocketPath = arguments.controlSocketPath,
      let handoffSocketPath = arguments.handoffSocketPath
    else {
      return
    }
    do {
      let server = try DoryVZMacControlServer(
        machineID: machineID,
        launchOperationID: operationID,
        stateDirectory: stateDirectoryURL.path,
        socketPath: controlSocketPath
      ) { [weak self] request in
        guard let self else {
          return VmmControlResponse(ok: false, message: "VZMac controller exited")
        }
        return await self.handleManagedControlRequest(request)
      }
      try server.start()
      controlServer = server
      try VmmHandoffClient.send(
        path: handoffSocketPath,
        ready: VmmReadyMessage(
          machineID: machineID,
          operationID: DoryOperationIdentity.canonical(operationID),
          agentBuild: "dory-vmm/vzmac",
          controlSocketPath: controlSocketPath,
          detail: "native ARM64 macOS is running through Virtualization.framework"
        )
      )
      handoffPublished = true
    } catch {
      terminalError = error
      requestStop()
    }
  }

  private func handleManagedControlRequest(
    _ request: VmmControlRequest
  ) async -> VmmControlResponse {
    guard request.qualificationFault == nil else {
      return VmmControlResponse(ok: false, message: "qualification faults are unavailable on this runtime")
    }
    switch request.command {
    case "macGuestToolsHealth":
      guard let machineID = arguments.machineID,
        request.targetMB == nil, request.statePath == nil,
        request.lifecycleAction == nil, request.operationID == nil,
        request.directoryShares == nil, request.reconnectChallenge == nil
      else {
        return VmmControlResponse(ok: false, message: "invalid Mac Guest Tools health request")
      }
      let snapshot = adapter.runtime.guestIntegrationService.snapshot
      let health = DoryMacGuestToolsHealth(
        machineID: machineID,
        state: DoryMacGuestToolsHealth.State(rawValue: snapshot.state.rawValue) ?? .disconnected,
        runtimeGeneration: snapshot.runtimeGeneration,
        toolsVersion: snapshot.guestToolsVersion,
        toolsBuild: snapshot.guestToolsBuild,
        guestOSVersion: snapshot.guestOSVersion,
        grantedCapabilities: snapshot.grantedCapabilities.map(\.rawValue).sorted(),
        lastHealthAtUnixMilliseconds: snapshot.lastHealthAt.map {
          UInt64($0.timeIntervalSince1970 * 1_000)
        },
        guestTimeUnixMilliseconds: snapshot.guestTimeUnixMilliseconds,
        lastErrorCode: snapshot.lastErrorCode
      )
      return VmmControlResponse(ok: true, macGuestTools: health)
    case "authenticateRuntime":
      guard request.targetMB == nil, request.statePath == nil,
        request.lifecycleAction == nil, request.operationID == nil,
        request.directoryShares == nil,
        let challenge = request.reconnectChallenge,
        let reconnectIdentity = arguments.reconnectIdentity
      else {
        return VmmControlResponse(
          ok: false, message: "invalid VZMac runtime authentication request")
      }
      do {
        return VmmControlResponse(
          ok: true,
          reconnect: try DoryRuntimeReconnectResponse(
            launchIdentity: reconnectIdentity,
            challenge: challenge,
            processIdentity: DoryHostProcessIdentity.capture(),
            runtimeState: adapter.observation.state.runtimeState
          )
        )
      } catch {
        return VmmControlResponse(ok: false, message: "\(error)")
      }
    case "pauseMachine":
      guard let receipt = lifecycleReceipt(request, expected: .preparePause) else {
        return VmmControlResponse(ok: false, message: "invalid VZMac pause request")
      }
      do {
        try await adapter.pause()
        return receipt
      } catch {
        return VmmControlResponse(ok: false, message: "\(error)")
      }
    case "resumeMachine":
      guard let receipt = lifecycleReceipt(request, expected: .resumed) else {
        return VmmControlResponse(ok: false, message: "invalid VZMac resume request")
      }
      do {
        try await adapter.resume()
        return receipt
      } catch {
        return VmmControlResponse(ok: false, message: "\(error)")
      }
    case "acknowledgeLifecycle":
      guard let action = request.lifecycleAction,
        let receipt = lifecycleReceipt(request, expected: action)
      else {
        return VmmControlResponse(
          ok: false,
          message: "invalid VZMac lifecycle acknowledgement"
        )
      }
      return receipt
    case "deviceTelemetry":
      guard request.targetMB == nil, request.statePath == nil,
        request.lifecycleAction == nil, request.operationID == nil,
        request.directoryShares == nil,
        request.reconnectChallenge == nil
      else {
        return VmmControlResponse(
          ok: false,
          message: "invalid VZMac telemetry request"
        )
      }
      return VmmControlResponse(
        ok: true,
        deviceTelemetry: controlServer?.nextTelemetrySnapshot()
      )
    case "saveMachineState":
      guard request.targetMB == nil,
        request.lifecycleAction == nil,
        request.operationID == nil,
        request.directoryShares == nil,
        request.reconnectChallenge == nil,
        let statePath = request.statePath
      else {
        return VmmControlResponse(
          ok: false,
          message: "native macOS saved-state payload is outside private saved-state authority"
        )
      }
      do {
        let acceptedStateURL = try acceptedSavedStateURL(statePath)
        if adapter.observation.state == .paused {
          try await adapter.resume()
        }
        try await adapter.suspend(to: acceptedStateURL)
        guard let stateDirectoryURL = arguments.stateDirectoryURL?.standardizedFileURL else {
          throw VmmControlError.rejected("managed state directory is unavailable")
        }
        try validateManagedSavedStateParent(
          stateDirectoryURL: stateDirectoryURL,
          leafName: acceptedStateURL.lastPathComponent,
          mustExist: true
        )
        let bundle = try DoryVZMacMachineBundle.load(
          from: arguments.machineBundleURL
        )
        guard bundle.manifest.installationState == .suspended else {
          throw DoryVZMacMachineBundleError.invalidBundle(
            "suspend completed without a durable suspended manifest"
          )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
          self?.finish()
        }
        return VmmControlResponse(ok: true)
      } catch {
        return VmmControlResponse(ok: false, message: "\(error)")
      }
    default:
      return VmmControlResponse(
        ok: false,
        message: "VZMac does not support control command \(request.command)"
      )
    }
  }

  private func lifecycleReceipt(
    _ request: VmmControlRequest,
    expected action: DoryLifecycleReceiptAction
  ) -> VmmControlResponse? {
    guard request.targetMB == nil, request.statePath == nil,
      request.directoryShares == nil,
      request.reconnectChallenge == nil,
      request.lifecycleAction == action,
      let operationID = request.operationID,
      DoryOperationIdentity.parseCanonical(operationID) != nil
    else {
      return nil
    }
    return VmmControlResponse(
      ok: true,
      lifecycleAction: action,
      operationID: operationID
    )
  }

  private func acceptedSavedStateURL(_ path: String) throws -> URL {
    guard let root = arguments.stateDirectoryURL?.standardizedFileURL else {
      throw VmmControlError.rejected("managed state directory is unavailable")
    }
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    try validateManagedSavedStatePathShape(
      candidate,
      stateDirectoryURL: root,
      expectedLeaf: .temporaryState
    )
    try validateManagedSavedStateParent(
      stateDirectoryURL: root,
      leafName: candidate.lastPathComponent,
      mustExist: false
    )
    return candidate
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    window.makeKeyAndOrderFront(nil)
    return true
  }

  func applicationDidResignActive(_ notification: Notification) {
    revokeClipboardActions()
  }

  func windowDidResignKey(_ notification: Notification) {
    guard notification.object as? NSWindow === window else { return }
    revokeClipboardActions()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let stopAction = installLifecycle.stopAction(state: adapter.observation.state)
    if stopAction == .cancelInstall || adapter.observation.state == .starting
      || adapter.observation.state == .restoring {
      window.makeKeyAndOrderFront(nil)
      // This boundary also serves NSRunningApplication.terminate(), the exact-process daemon
      // fallback on early Sonoma. A daemon cancellation must not wait for a human alert.
      requestStop()
      return .terminateCancel
    }
    if adapter.observation.state == .running {
      window.orderOut(nil)
      requestStop()
    } else {
      window.makeKeyAndOrderFront(nil)
      NSSound.beep()
    }
    return .terminateCancel
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender === window else {
      sender.orderOut(nil)
      return false
    }
    if installLifecycle.isInstallingRestore {
      confirmInstallationCancellation()
      return false
    }
    if adapter.observation.state == .running {
      sender.orderOut(nil)
      requestStop()
    } else {
      NSSound.beep()
    }
    return false
  }

  private func confirmInstallationCancellation() {
    guard !installCancellationPromptVisible, !stopRequested,
      installLifecycle.isInstallingRestore else { return }
    installCancellationPromptVisible = true
    let alert = NSAlert()
    alert.messageText = "Cancel macOS Installation?"
    alert.informativeText = "Dory will keep this machine's disk and identity so you can retry the installation. The original restore image will not be changed."
    alert.addButton(withTitle: "Keep Installing")
    alert.addButton(withTitle: "Cancel Installation")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.installCancellationPromptVisible = false
      // Installation may have finished while the question was visible. Never turn a stale
      // answer into a shutdown request against the newly started guest.
      guard response == .alertSecondButtonReturn,
        self.installLifecycle.isInstallingRestore else { return }
      self.requestStop()
    }
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    guard notification.object as? NSWindow === window else { return }
    lifecycleTrace?.record(.windowResized)
  }

  func windowDidMiniaturize(_ notification: Notification) {
    guard notification.object as? NSWindow === window else { return }
    revokeClipboardActions()
    lifecycleTrace?.record(.windowMiniaturized)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    guard notification.object as? NSWindow === window else { return }
    lifecycleTrace?.record(.windowRestored)
  }

  @objc private func toggleFullScreen(_ sender: Any?) {
    window.toggleFullScreen(sender)
  }

  @objc private func openURLInGuest(_ sender: Any?) {
    guard canOpenURLInGuest else {
      NSSound.beep()
      return
    }
    let alert = NSAlert()
    alert.messageText = "Open URL in Mac Guest"
    alert.informativeText = "Enter an HTTP or HTTPS address. Guest Tools must be connected."
    alert.addButton(withTitle: "Open")
    alert.addButton(withTitle: "Cancel")
    let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    address.placeholderString = "https://example.org/"
    alert.accessoryView = address
    alert.beginSheetModal(for: window) { [weak self, address] response in
      guard response == .alertFirstButtonReturn, let self else { return }
      let input = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          guard let components = URLComponents(string: input),
            components.scheme == "http" || components.scheme == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            let url = components.url
          else {
            throw DoryVZMacDesktopError.invalidGuestURL
          }
          try await self.adapter.openURLInGuest(url)
        } catch {
          let failure = NSAlert()
          failure.alertStyle = .warning
          failure.messageText = "Could Not Open URL in Guest"
          failure.informativeText = String(describing: error)
          failure.addButton(withTitle: "OK")
          failure.beginSheetModal(for: self.window) { _ in }
        }
      }
    }
  }

  private var canOpenURLInGuest: Bool {
    let tools = adapter.runtime.guestIntegrationService.snapshot
    return adapter.observation.state == .running
      && tools.state == .healthy
      && tools.grantedCapabilities.contains(.openURL)
  }

  @objc private func sendFileToGuest(_ sender: Any?) {
    guard canSendFileToGuest else { NSSound.beep(); return }
    let panel = NSOpenPanel()
    panel.message = "Choose a file to send to this Mac guest."
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self, panel] response in
      guard response == .OK, let self, let url = panel.url else { return }
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await self.adapter.sendFileToGuest(at: url)
        } catch {
          let failure = NSAlert()
          failure.alertStyle = .warning
          failure.messageText = "Could Not Send File to Guest"
          failure.informativeText = String(describing: error)
          failure.addButton(withTitle: "OK")
          failure.beginSheetModal(for: self.window) { _ in }
        }
      }
    }
  }

  private var canSendFileToGuest: Bool {
    let tools = adapter.runtime.guestIntegrationService.snapshot
    return adapter.observation.state == .running
      && tools.state == .healthy
      && tools.grantedCapabilities.contains(.filePush)
  }

  @objc private func saveFileFromGuest(_ sender: Any?) {
    guard canSaveFileFromGuest else { NSSound.beep(); return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let offer = try await self.adapter.fileOfferedByGuest()
        let panel = NSSavePanel()
        panel.message = "Save the file explicitly selected in Dory Guest Tools."
        panel.nameFieldStringValue = offer.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: self.window) { [weak self, panel] response in
          guard response == .OK, let self, let destination = panel.url else { return }
          Task { @MainActor [weak self] in
            guard let self else { return }
            do {
              try await self.adapter.receiveFileFromGuest(offer, to: destination)
            } catch {
              let failure = NSAlert()
              failure.alertStyle = .warning
              failure.messageText = "Could Not Save File from Guest"
              failure.informativeText = String(describing: error)
              failure.addButton(withTitle: "OK")
              failure.beginSheetModal(for: self.window) { _ in }
            }
          }
        }
      } catch {
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = "No Guest File Is Ready"
        failure.informativeText =
          "In Dory Guest Tools, choose a file for the host first. \(error)"
        failure.addButton(withTitle: "OK")
        failure.beginSheetModal(for: self.window) { _ in }
      }
    }
  }

  private var canSaveFileFromGuest: Bool {
    let tools = adapter.runtime.guestIntegrationService.snapshot
    return adapter.observation.state == .running
      && tools.state == .healthy
      && tools.grantedCapabilities.contains(.filePull)
  }

  @objc private func copyTextFromGuest(_ sender: Any?) {
    guard canCopyTextFromGuest else {
      NSSound.beep()
      return
    }
    runClipboardAction(timeoutNanoseconds: 5_000_000_000,
      failureTitle: "Could Not Copy Text from Guest") { [weak self] ticket in
      guard let self else { return }
      let text = try await adapter.readClipboardTextFromGuest()
      try publishClipboardResult(ticket) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
          throw DoryVZMacGuestIntegrationError.unavailable
        }
      }
    }
  }

  private var canCopyTextFromGuest: Bool {
    let tools = adapter.runtime.guestIntegrationService.snapshot
    return isClipboardInteractive && !clipboardActions.isBusy
      && tools.state == .healthy
      && tools.grantedCapabilities.contains(.clipboardTextRead)
  }

  @objc private func pasteTextIntoGuest(_ sender: Any?) {
    guard canPasteTextIntoGuest,
      let text = NSPasteboard.general.string(forType: .string) else {
      NSSound.beep()
      return
    }
    runClipboardAction(timeoutNanoseconds: 5_000_000_000,
      failureTitle: "Could Not Paste Text into Guest") { [weak self] _ in
      guard let self else { return }
      try await adapter.writeClipboardTextToGuest(text)
    }
  }

  private var canPasteTextIntoGuest: Bool {
    let tools = adapter.runtime.guestIntegrationService.snapshot
    return isClipboardInteractive && !clipboardActions.isBusy
      && tools.state == .healthy
      && tools.grantedCapabilities.contains(.clipboardTextWrite)
  }

  @objc private func copyImageFromGuest(_ sender: Any?) {
    guard canCopyImageFromGuest else {
      NSSound.beep()
      return
    }
    runClipboardAction(timeoutNanoseconds: 10_000_000_000,
      failureTitle: "Could Not Copy Image from Guest") { [weak self] ticket in
      guard let self else { return }
      let png = try await adapter.readClipboardPNGFromGuest()
      guard let image = NSBitmapImageRep(data: png), image.bitmapData != nil else {
        throw DoryVZMacGuestIntegrationError.denied
      }
      // Bounded image decoding precedes the final original-budget publication check.
      try publishClipboardResult(ticket) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(png, forType: .png) else {
          throw DoryVZMacGuestIntegrationError.unavailable
        }
      }
    }
  }

  private var canCopyImageFromGuest: Bool {
    let tools = adapter.runtime.guestIntegrationService.snapshot
    return isClipboardInteractive && !clipboardActions.isBusy
      && tools.state == .healthy
      && tools.grantedCapabilities.contains(.clipboardImageRead)
  }

  @objc private func pasteImageIntoGuest(_ sender: Any?) {
    guard canPasteImageIntoGuest,
      let png = Self.inlinePasteboardPNG() else {
      NSSound.beep()
      return
    }
    runClipboardAction(timeoutNanoseconds: 10_000_000_000,
      failureTitle: "Could Not Paste Image into Guest") { [weak self] _ in
      guard let self else { return }
      try await adapter.writeClipboardPNGToGuest(png)
    }
  }

  private var canPasteImageIntoGuest: Bool {
    let tools = adapter.runtime.guestIntegrationService.snapshot
    return isClipboardInteractive && !clipboardActions.isBusy
      && tools.state == .healthy
      && tools.grantedCapabilities.contains(.clipboardImageWrite)
  }

  private var isClipboardInteractive: Bool {
    guard !didFinish, !stopRequested, application.isActive, window.isKeyWindow,
      window.isVisible, !window.isMiniaturized, adapter.observation.state == .running else {
      return false
    }
    var uid = uid_t(0), gid = gid_t(0)
    guard let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
      user != "loginwindow", user != "_mbsetupuser", uid != 0 else { return false }
    return uid == geteuid()
  }

  private func permitsClipboardAction(_ ticket: DoryVZMacClipboardActionAuthority.Ticket) -> Bool {
    !Task.isCancelled && clipboardActions.permits(ticket,
      sessionIdentity: adapter.runtime.guestIntegrationService.clipboardSessionIdentity,
      pasteboardChangeCount: NSPasteboard.general.changeCount,
      isInteractive: isClipboardInteractive,
      nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
  }

  private func publishClipboardResult(
    _ ticket: DoryVZMacClipboardActionAuthority.Ticket, mutation: () throws -> Void
  ) rethrows {
    guard !Task.isCancelled else { return }
    try clipboardActions.performIfCurrent(ticket,
      sessionIdentity: adapter.runtime.guestIntegrationService.clipboardSessionIdentity,
      pasteboardChangeCount: NSPasteboard.general.changeCount,
      isInteractive: isClipboardInteractive,
      nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds, mutation: mutation)
  }

  private func runClipboardAction(
    timeoutNanoseconds: UInt64, failureTitle: String,
    operation: @escaping @MainActor @Sendable (DoryVZMacClipboardActionAuthority.Ticket) async throws -> Void
  ) {
    let now = DispatchTime.now().uptimeNanoseconds
    guard let ticket = clipboardActions.begin(
      sessionIdentity: adapter.runtime.guestIntegrationService.clipboardSessionIdentity,
      pasteboardChangeCount: NSPasteboard.general.changeCount,
      isInteractive: isClipboardInteractive, nowUptimeNanoseconds: now,
      timeoutNanoseconds: timeoutNanoseconds) else {
      NSSound.beep()
      return
    }
    clipboardDeadlineTask = Task { @MainActor [weak self] in
      let observedAt = DispatchTime.now().uptimeNanoseconds
      if observedAt < ticket.deadlineUptimeNanoseconds {
        do { try await Task.sleep(nanoseconds: ticket.deadlineUptimeNanoseconds - observedAt) }
        catch { return }
      }
      guard let self, self.clipboardActions.owns(ticket) else { return }
      // Cancelling the task tears down only its exact sent Guest Tools request/session.
      self.revokeClipboardActions()
    }
    clipboardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { finishClipboardAction(ticket) }
      // The main-actor task may start after focus, session, or host clipboard changed.
      guard permitsClipboardAction(ticket) else { return }
      do { try await operation(ticket) }
      catch {
        // A cancelled old task must neither replace the clipboard nor open a stale alert over
        // a successor window/session. Our own failed set may have changed changeCount already.
        guard !Task.isCancelled, clipboardActions.owns(ticket), isClipboardInteractive,
          adapter.runtime.guestIntegrationService.clipboardSessionIdentity == ticket.sessionIdentity,
          DispatchTime.now().uptimeNanoseconds < ticket.deadlineUptimeNanoseconds else { return }
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = failureTitle
        failure.informativeText = String(describing: error)
        failure.addButton(withTitle: "OK")
        failure.beginSheetModal(for: window) { _ in }
      }
    }
  }

  private func finishClipboardAction(_ ticket: DoryVZMacClipboardActionAuthority.Ticket) {
    guard clipboardActions.finish(ticket) else { return }
    clipboardDeadlineTask?.cancel()
    clipboardDeadlineTask = nil
    clipboardTask = nil
  }

  private func revokeClipboardActions() {
    clipboardActions.revoke()
    clipboardTask?.cancel()
    clipboardDeadlineTask?.cancel()
    clipboardTask = nil
    clipboardDeadlineTask = nil
  }

  private static func inlinePasteboardPNG() -> Data? {
    let pasteboard = NSPasteboard.general
    if let png = pasteboard.data(forType: .png),
      (try? DoryMacGuestIntegrationWire.validateClipboardPNG(png)) != nil,
      NSBitmapImageRep(data: png)?.bitmapData != nil
    {
      return png
    }
    guard let tiff = pasteboard.data(forType: .tiff),
      let image = Self.boundedInlineTIFF(tiff),
      let png = image.representation(using: .png, properties: [:]),
      (try? DoryMacGuestIntegrationWire.validateClipboardPNG(png)) != nil
    else { return nil }
    return png
  }

  private static func boundedInlineTIFF(_ tiff: Data) -> NSBitmapImageRep? {
    guard tiff.count <= DoryMacGuestIntegrationWire.maximumImageBytes,
      let source = CGImageSourceCreateWithData(tiff as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      (1...8_192).contains(width.intValue), (1...8_192).contains(height.intValue),
      Int64(width.intValue) * Int64(height.intValue) <= 16_777_216,
      let image = NSBitmapImageRep(data: tiff), image.bitmapData != nil
    else { return nil }
    return image
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(openURLInGuest(_:)) {
      return canOpenURLInGuest
    }
    if menuItem.action == #selector(sendFileToGuest(_:)) {
      return canSendFileToGuest
    }
    if menuItem.action == #selector(saveFileFromGuest(_:)) {
      return canSaveFileFromGuest
    }
    if menuItem.action == #selector(copyTextFromGuest(_:)) {
      return canCopyTextFromGuest
    }
    if menuItem.action == #selector(pasteTextIntoGuest(_:)) {
      return canPasteTextIntoGuest
    }
    if menuItem.action == #selector(copyImageFromGuest(_:)) {
      return canCopyImageFromGuest
    }
    if menuItem.action == #selector(pasteImageIntoGuest(_:)) {
      return canPasteImageIntoGuest
    }
    return true
  }

  private func installViewMenu() {
    let mainMenu = NSMenu()
    let viewRoot = NSMenuItem()
    let viewMenu = NSMenu(title: "View")
    let fullscreen = NSMenuItem(
      title: "Toggle Full Screen",
      action: #selector(toggleFullScreen(_:)),
      keyEquivalent: "f"
    )
    fullscreen.keyEquivalentModifierMask = [.command, .control]
    fullscreen.target = self
    viewMenu.addItem(fullscreen)
    viewRoot.submenu = viewMenu
    mainMenu.addItem(viewRoot)
    let guestRoot = NSMenuItem()
    let guestMenu = NSMenu(title: "Guest")
    let openURL = NSMenuItem(
      title: "Open URL in Guest…",
      action: #selector(openURLInGuest(_:)),
      keyEquivalent: ""
    )
    openURL.target = self
    guestMenu.addItem(openURL)
    let sendFile = NSMenuItem(
      title: "Send File to Guest…",
      action: #selector(sendFileToGuest(_:)), keyEquivalent: ""
    )
    sendFile.target = self
    guestMenu.addItem(sendFile)
    let saveFile = NSMenuItem(
      title: "Save File from Guest…",
      action: #selector(saveFileFromGuest(_:)), keyEquivalent: ""
    )
    saveFile.target = self
    guestMenu.addItem(saveFile)
    let copyText = NSMenuItem(
      title: "Copy Text from Guest",
      action: #selector(copyTextFromGuest(_:)),
      keyEquivalent: ""
    )
    copyText.target = self
    guestMenu.addItem(copyText)
    let pasteText = NSMenuItem(
      title: "Paste Text into Guest",
      action: #selector(pasteTextIntoGuest(_:)),
      keyEquivalent: ""
    )
    pasteText.target = self
    guestMenu.addItem(pasteText)
    let copyImage = NSMenuItem(
      title: "Copy Image from Guest",
      action: #selector(copyImageFromGuest(_:)),
      keyEquivalent: ""
    )
    copyImage.target = self
    guestMenu.addItem(copyImage)
    let pasteImage = NSMenuItem(
      title: "Paste Image into Guest",
      action: #selector(pasteImageIntoGuest(_:)),
      keyEquivalent: ""
    )
    pasteImage.target = self
    guestMenu.addItem(pasteImage)
    guestRoot.submenu = guestMenu
    mainMenu.addItem(guestRoot)
    application.mainMenu = mainMenu
  }
}

private final class DoryVZMacControlServer: @unchecked Sendable {
  typealias Handler = @Sendable (VmmControlRequest) async -> VmmControlResponse

  private let machineID: String
  private let launchOperationID: UUID
  private let stateDirectory: String
  private let socketPath: String
  private let handler: Handler
  private let queue = DispatchQueue(label: "dev.dory.dory-vmm.vzmac-control")
  private let clientSlots = DispatchSemaphore(value: 8)
  private let lock = NSLock()
  private var socketOwner: VmmControlSocketListener?
  private var sampleSequence: UInt64 = 0

  init(
    machineID: String,
    launchOperationID: UUID,
    stateDirectory: String,
    socketPath: String,
    handler: @escaping Handler
  ) throws {
    let canonicalState = URL(fileURLWithPath: stateDirectory, isDirectory: true)
      .standardizedFileURL.path
    guard canonicalState == stateDirectory,
      socketPath.hasPrefix("/"), !socketPath.contains("\0")
    else {
      throw VmmControlError.rejected("invalid managed VZMac control paths")
    }
    self.machineID = machineID
    self.launchOperationID = launchOperationID
    self.stateDirectory = canonicalState
    self.socketPath = socketPath
    self.handler = handler
  }

  func start() throws {
    let listener = try lock.withLock { () throws -> VmmControlSocketListener? in
      guard socketOwner == nil else { return nil }
      let owner = try VmmControlSocketListener(path: socketPath)
      socketOwner = owner
      return owner
    }
    guard let listener else { return }
    queue.async { [weak self] in self?.acceptLoop(listener: listener) }
  }

  func stop() {
    let owner = lock.withLock { () -> VmmControlSocketListener? in
      let owner = socketOwner
      socketOwner = nil
      return owner
    }
    owner?.stop()
  }

  func nextTelemetrySnapshot() -> DoryDeviceTelemetrySnapshot {
    let sequence = lock.withLock { () -> UInt64 in
      sampleSequence = sampleSequence == UInt64.max ? 1 : sampleSequence + 1
      return sampleSequence
    }
    return DoryDeviceTelemetrySnapshot(
      machineID: machineID,
      operationID: DoryOperationIdentity.canonical(launchOperationID),
      backend: .appleVirtualizationFramework,
      sampleSequence: sequence,
      sampledAtUnixMilliseconds: UInt64(
        max(
          1,
          Int64(Date().timeIntervalSince1970 * 1_000)
        )),
      monotonicNanoseconds: max(1, DispatchTime.now().uptimeNanoseconds),
      devices: [
        DoryDeviceTelemetryDevice(
          id: "vzmac-platform",
          kind: .platform,
          health: .unavailable,
          metrics: [
            .unavailable(
              .queueStateChanges,
              reason: "Virtualization.framework does not expose device queue counters")
          ]
        )
      ]
    )
  }

  private func acceptLoop(listener: VmmControlSocketListener) {
    while true {
      let client: Int32
      do {
        switch try listener.acceptClient() {
        case .client(let descriptor): client = descriptor
        case .retry: continue
        case .stopped: return
        }
      } catch {
        return
      }
      guard lock.withLock({ socketOwner === listener }) else {
        close(client)
        return
      }
      let slots = clientSlots
      guard slots.wait(timeout: .now()) == .success else {
        close(client)
        continue
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        defer { slots.signal() }
        guard let self else {
          close(client)
          return
        }
        self.handle(clientFD: client)
      }
    }
  }

  private func handle(clientFD: Int32) {
    defer { close(clientFD) }
    let response: VmmControlResponse
    do {
      let data = try VmmControlSocketIO.readRequestData(from: clientFD)
      let request = try JSONDecoder().decode(VmmControlRequest.self, from: data)
      let box = DoryVZMacControlResponseBox()
      Task {
        let response = await handler(request)
        box.publish(response)
      }
      response = box.wait()
    } catch {
      response = VmmControlResponse(ok: false, message: "\(error)")
    }
    do {
      try VmmControlSocketIO.writeResponseData(try JSONEncoder().encode(response), to: clientFD)
    } catch {
      FileHandle.standardError.write(
        Data(
          "dory-vmm VZMac control response failed: \(error)\n".utf8
        ))
    }
  }

  deinit { stop() }
}

private final class DoryVZMacControlResponseBox: @unchecked Sendable {
  private let condition = NSCondition()
  private var response: VmmControlResponse?

  func publish(_ response: VmmControlResponse) {
    condition.lock()
    self.response = response
    condition.broadcast()
    condition.unlock()
  }

  func wait() -> VmmControlResponse {
    condition.lock()
    while response == nil { condition.wait() }
    let result = response!
    condition.unlock()
    return result
  }
}
