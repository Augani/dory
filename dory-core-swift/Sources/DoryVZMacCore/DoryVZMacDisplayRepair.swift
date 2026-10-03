import CryptoKit
import Darwin
import Foundation

/// Resumable filesystem part of the existing, explicitly requested one-display repair.
/// The machine lease remains the lifecycle authority. Intent is immutable; recovery uses
/// exact old/new bytes and pinned directory identities, never a best-effort rollback.
enum DoryVZMacDisplayRepair {
  enum Checkpoint: CaseIterable {
    case intentCommitted, backupCommitted, statePreserved, manifestCommitted, receiptCommitted, completed
  }

  struct IO {
    var metadata = DoryVZMacMetadataFile.WriteIO()
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
  }

  private struct Identity: Codable, Equatable {
    let device: Int64
    let inode: UInt64

    init(_ value: stat) { device = Int64(value.st_dev); inode = UInt64(value.st_ino) }
  }

  private struct Intent: Codable, Equatable {
    static let schema = "dory.vzmac-display-repair-intent@1"
    let schema: String
    let original: Data
    let repaired: Data
    let receipt: DoryVZMacDisplayRepairReceipt
    let savedState: Identity?
    let managedSavedState: Identity?
    let preservesManagedSavedState: Bool?
  }

  // Two individually bounded manifests, encoded as base64, plus the small receipt.
  private static let maximumIntentBytes = 3 * DoryVZMacMachineBundle.maximumManifestBytes + 4_096

  static func perform(
    at rootURL: URL, keepingDisplayAt selectedIndex: Int,
    preserveManagedSavedState: Bool = false, expectedOriginalManifestSHA256: String? = nil,
    holdingLease: DoryVZMacMachineLease? = nil, io: IO = IO()
  ) throws -> DoryVZMacDisplayRepairReceipt {
    guard rootURL.isFileURL, !rootURL.path.contains("\0") else { throw invalid("nonlocal repair root") }
    let lease: DoryVZMacMachineLease
    if let holdingLease {
      guard holdingLease.rootURL == rootURL else { throw invalid("display repair lease belongs to another bundle") }
      lease = holdingLease
    } else { lease = try DoryVZMacMachineLease(rootURL: rootURL) }
    defer { withExtendedLifetime(lease) {} }
    let rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootFD >= 0 else { throw failure("open display repair root") }
    defer { close(rootFD) }
    var rootStatus = stat()
    guard fstat(rootFD, &rootStatus) == 0 else { throw failure("inspect display repair root") }
    try requireOwnedDirectory(rootStatus)
    let rootIdentity = Identity(rootStatus)
    let managedFD = try openManagedParent(rootURL, enabled: preserveManagedSavedState)
    defer { if let managedFD { close(managedFD) } }
    let journalURL = file(rootURL, DoryVZMacMachineBundle.displayRepairJournalName)
    if let expectedOriginalManifestSHA256,
      try entry(rootFD, DoryVZMacMachineBundle.displayRepairJournalName) == nil,
      try entry(rootFD, DoryVZMacMachineBundle.displayRepairReceiptName) != nil {
      // A visible receipt is not a durability proof. Only an explicit, content-bound retry
      // may re-flush the completed transformation and both RAM-preservation directories.
      guard let assessment = try inspect(at: rootURL, preserveManagedSavedState: preserveManagedSavedState),
        assessment.bundleRepairCompleted, assessment.originalManifestSHA256 == expectedOriginalManifestSHA256,
        assessment.pendingSelectedDisplayIndex == selectedIndex else {
        throw invalid("completed display repair does not match the requested original and choice")
      }
      let receipt = try JSONDecoder().decode(DoryVZMacDisplayRepairReceipt.self,
        from: DoryVZMacMetadataFile.read(from: file(rootURL, DoryVZMacMachineBundle.displayRepairReceiptName)))
      guard receipt.preservedSavedStateName == nil || receipt.preservedSavedStateIdentity != nil,
        receipt.preservedManagedSavedStateName == nil || receipt.preservedManagedSavedStateIdentity != nil else {
        throw invalid("legacy completed repair lacks immutable saved-RAM archive identity")
      }
      let completed = Intent(schema: Intent.schema,
        original: try DoryVZMacMetadataFile.read(from: file(rootURL, DoryVZMacMachineBundle.preDisplayRepairManifestName)),
        repaired: try DoryVZMacMetadataFile.read(from: file(rootURL, DoryVZMacMachineBundle.manifestName)),
        receipt: receipt,
        savedState: try stateIdentity(rootFD, DoryVZMacMachineBundle.incompatibleSavedStateName),
        managedSavedState: try managedFD.flatMap { try stateIdentity($0, DoryVZMacMachineBundle.incompatibleManagedSavedStateName) },
        preservesManagedSavedState: preserveManagedSavedState ? true : nil)
      try validate(completed)
      try validateCurrent(completed, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD,
        requireIntent: false, requireBackup: true, requirePreserved: true, requireRepaired: true, requireReceipt: true)
      for name in [DoryVZMacMachineBundle.preDisplayRepairManifestName,
        DoryVZMacMachineBundle.manifestName, DoryVZMacMachineBundle.displayRepairReceiptName] {
        try synchronizeDirectory(rootFD, barrier: file(rootURL, name), io: io.metadata)
      }
      if let managedFD {
        try synchronizeDirectory(managedFD, barrier: file(rootURL, DoryVZMacMachineBundle.displayRepairReceiptName),
          barrierDescriptor: rootFD, io: io.metadata)
      }
      try validateRoot(rootURL, identity: rootIdentity)
      try validateCurrent(completed, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD,
        requireIntent: false, requireBackup: true, requirePreserved: true, requireRepaired: true, requireReceipt: true)
      guard try entry(rootFD, DoryVZMacMachineBundle.displayRepairJournalName) == nil else {
        throw invalid("completed display repair acquired an unexpected intent")
      }
      return receipt
    }
    let intent: Intent
    if let bytes = try DoryVZMacMetadataFile.readIfPresent(
      from: journalURL, maximumBytes: maximumIntentBytes
    ) {
      intent = try JSONDecoder().decode(Intent.self, from: bytes)
      try validate(intent)
      guard expectedOriginalManifestSHA256 == nil
        || expectedOriginalManifestSHA256 == intent.receipt.originalManifestSHA256 else {
        throw invalid("pending display repair does not match the requested original")
      }
      guard (intent.preservesManagedSavedState ?? false) == preserveManagedSavedState else {
        throw invalid("retry must retain the original managed saved-state preservation choice")
      }
      guard selectedIndex == intent.receipt.selectedDisplayIndex else {
        throw invalid(
          "pending display repair selected index \(intent.receipt.selectedDisplayIndex); "
            + "retry with --keep-display-index \(intent.receipt.selectedDisplayIndex)"
        )
      }
    } else {
      guard try entry(rootFD, DoryVZMacMachineBundle.displayRepairReceiptName) == nil else {
        throw invalid("display-topology repair is already complete")
      }
      let backup = try DoryVZMacMetadataFile.readIfPresent(
        from: file(rootURL, DoryVZMacMachineBundle.preDisplayRepairManifestName)
      )
      let original = try backup ?? DoryVZMacMetadataFile.read(
        from: file(rootURL, DoryVZMacMachineBundle.manifestName)
      )
      guard expectedOriginalManifestSHA256 == nil
        || expectedOriginalManifestSHA256 == SHA256.hash(data: original).map({ String(format: "%02x", $0) }).joined() else {
        throw invalid("display repair source changed since confirmation")
      }
      let source = try stateIdentity(rootFD, DoryVZMacMachineBundle.suspendedStateDirectoryName)
      let preserved = try stateIdentity(rootFD, DoryVZMacMachineBundle.incompatibleSavedStateName)
      guard source == nil || preserved == nil, preserved == nil || backup != nil else {
        throw invalid("saved-state preservation has conflicting or unowned repair artifacts")
      }
      let state = source ?? preserved
      let managedState = try managedStateIdentity(managedFD, backupExists: backup != nil)
      let plan = try makePlan(
        original: original, selectedIndex: selectedIndex, hasSavedState: state != nil,
        hasManagedSavedState: managedState != nil,
        savedStateIdentity: identityName(state), managedSavedStateIdentity: identityName(managedState),
        repairedAt: ISO8601DateFormatter().string(from: Date())
      )
      intent = Intent(
        schema: Intent.schema, original: original, repaired: plan.bytes,
        receipt: plan.receipt, savedState: state, managedSavedState: managedState,
        preservesManagedSavedState: preserveManagedSavedState ? true : nil
      )
      try validateCurrent(intent, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD, requireIntent: false)
      try validateRoot(rootURL, identity: rootIdentity)
      try DoryVZMacMetadataFile.write(
        encode(intent), to: journalURL, maximumBytes: maximumIntentBytes,
        replacingExisting: false, io: io.metadata
      )
    }
    try validateRoot(rootURL, identity: rootIdentity)
    try validateCurrent(intent, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD)
    // Re-flush a visible intent from an earlier attempt before proceeding. A crash or
    // late publication error may have occurred before that attempt finished its barrier.
    try synchronizeDirectory(rootFD, barrier: journalURL, io: io.metadata)
    try io.checkpoint(.intentCommitted)
    try validateRoot(rootURL, identity: rootIdentity)
    try validateCurrent(intent, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD)
    let backupURL = file(rootURL, DoryVZMacMachineBundle.preDisplayRepairManifestName)
    let backupExists = try entry(rootFD, DoryVZMacMachineBundle.preDisplayRepairManifestName) != nil
    try DoryVZMacMetadataFile.write(
      intent.original, to: backupURL, replacingExisting: backupExists, io: io.metadata
    )
    try io.checkpoint(.backupCommitted)
    try validateRoot(rootURL, identity: rootIdentity)
    try validateCurrent(intent, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD)
    if intent.savedState != nil {
      if try entry(rootFD, DoryVZMacMachineBundle.suspendedStateDirectoryName) != nil {
        guard renameatx_np(
          rootFD, DoryVZMacMachineBundle.suspendedStateDirectoryName,
          rootFD, DoryVZMacMachineBundle.incompatibleSavedStateName, UInt32(RENAME_EXCL)
        ) == 0 else { throw failure("preserve incompatible saved state exclusively") }
      }
      // Also flush on retries where the rename is already visible. RAM never returns
      // to its old resumable path, even if a later manifest/receipt write fails.
      try synchronizeDirectory(rootFD, barrier: journalURL, io: io.metadata)
    }
    if let managedFD, intent.managedSavedState != nil {
      if try entry(managedFD, DoryVZMacMachineBundle.managedSavedStateName) != nil {
        guard renameatx_np(
          managedFD, DoryVZMacMachineBundle.managedSavedStateName,
          managedFD, DoryVZMacMachineBundle.incompatibleManagedSavedStateName, UInt32(RENAME_EXCL)
        ) == 0 else { throw failure("preserve incompatible managed saved state exclusively") }
      }
      try synchronizeDirectory(managedFD, barrier: journalURL, barrierDescriptor: rootFD, io: io.metadata)
    }
    try io.checkpoint(.statePreserved)
    try validateRoot(rootURL, identity: rootIdentity)
    try validateCurrent(intent, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD,
      requireBackup: true, requirePreserved: true)
    try DoryVZMacMetadataFile.write(
      intent.repaired, to: file(rootURL, DoryVZMacMachineBundle.manifestName), io: io.metadata
    )
    try io.checkpoint(.manifestCommitted)
    try validateRoot(rootURL, identity: rootIdentity)
    try validateCurrent(
      intent, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD, requireBackup: true,
      requirePreserved: true, requireRepaired: true
    )
    let receiptExists = try entry(rootFD, DoryVZMacMachineBundle.displayRepairReceiptName) != nil
    try DoryVZMacMetadataFile.write(
      encode(intent.receipt), to: file(rootURL, DoryVZMacMachineBundle.displayRepairReceiptName),
      replacingExisting: receiptExists, io: io.metadata
    )
    try io.checkpoint(.receiptCommitted)
    try validateRoot(rootURL, identity: rootIdentity)
    try validateCurrent(
      intent, at: rootURL, descriptor: rootFD, managedDescriptor: managedFD, requireBackup: true,
      requirePreserved: true, requireRepaired: true, requireReceipt: true
    )
    try DoryVZMacMetadataFile.remove(at: journalURL, io: io.metadata)
    try io.checkpoint(.completed)
    return intent.receipt
  }

  private static func validate(_ intent: Intent) throws {
    guard intent.schema == Intent.schema,
      ISO8601DateFormatter().date(from: intent.receipt.repairedAt) != nil
    else { throw invalid("unknown or malformed display repair intent") }
    let plan = try makePlan(
      original: intent.original, selectedIndex: intent.receipt.selectedDisplayIndex,
      hasSavedState: intent.savedState != nil, hasManagedSavedState: intent.managedSavedState != nil,
      savedStateIdentity: intent.receipt.preservedSavedStateIdentity == nil ? nil : identityName(intent.savedState),
      managedSavedStateIdentity: intent.receipt.preservedManagedSavedStateIdentity == nil ? nil : identityName(intent.managedSavedState),
      repairedAt: intent.receipt.repairedAt
    )
    guard plan.bytes == intent.repaired, plan.receipt == intent.receipt,
      intent.managedSavedState == nil || intent.preservesManagedSavedState == true else {
      throw invalid("repair intent bytes or receipt do not match the recorded transformation")
    }
  }

  private static func validateCurrent(
    _ intent: Intent, at root: URL, descriptor: Int32, managedDescriptor: Int32? = nil, requireIntent: Bool = true,
    requireBackup: Bool = false, requirePreserved: Bool = false,
    requireRepaired: Bool = false, requireReceipt: Bool = false
  ) throws {
    let active = try DoryVZMacMetadataFile.readIfPresent(
      from: file(root, DoryVZMacMachineBundle.displayRepairJournalName), maximumBytes: maximumIntentBytes
    )
    if let active {
      guard try JSONDecoder().decode(Intent.self, from: active) == intent else {
        throw invalid("display repair intent changed during the operation")
      }
    } else if requireIntent { throw invalid("display repair intent disappeared") }
    let current = try DoryVZMacMetadataFile.read(from: file(root, DoryVZMacMachineBundle.manifestName))
    guard (current == intent.original || current == intent.repaired),
      !requireRepaired || current == intent.repaired else {
      throw invalid("manifest changed outside the pending display repair")
    }
    let backup = try DoryVZMacMetadataFile.readIfPresent(
      from: file(root, DoryVZMacMachineBundle.preDisplayRepairManifestName)
    )
    guard (backup == nil || backup == intent.original), !requireBackup || backup != nil else {
      throw invalid("original display repair backup differs or disappeared")
    }
    let receipt = try DoryVZMacMetadataFile.readIfPresent(
      from: file(root, DoryVZMacMachineBundle.displayRepairReceiptName)
    )
    let expectedReceipt = try encode(intent.receipt)
    guard (receipt == nil || receipt == expectedReceipt), !requireReceipt || receipt != nil else {
      throw invalid("display repair receipt differs or disappeared")
    }
    let source = try stateIdentity(descriptor, DoryVZMacMachineBundle.suspendedStateDirectoryName)
    let preserved = try stateIdentity(descriptor, DoryVZMacMachineBundle.incompatibleSavedStateName)
    if let expected = intent.savedState {
      guard (source == expected && preserved == nil) || (source == nil && preserved == expected) else {
        throw invalid("saved-state directory changed outside the pending display repair")
      }
      guard !requirePreserved || source == nil else {
        throw invalid("incompatible RAM returned to its resumable path")
      }
      if current == intent.repaired && source != nil {
        throw invalid("repaired manifest cannot retain a resumable incompatible RAM path")
      }
    } else if source != nil || preserved != nil {
      throw invalid("an unexpected saved-state directory appeared during display repair")
    }
    if let managedDescriptor {
      try validateManagedParent(root, descriptor: managedDescriptor)
      let source = try stateIdentity(managedDescriptor, DoryVZMacMachineBundle.managedSavedStateName)
      let preserved = try stateIdentity(managedDescriptor, DoryVZMacMachineBundle.incompatibleManagedSavedStateName)
      if let expected = intent.managedSavedState {
        guard (source == expected && preserved == nil) || (source == nil && preserved == expected),
          !requirePreserved || source == nil, current != intent.repaired || source == nil else {
          throw invalid("managed saved-state directory changed outside the pending display repair")
        }
      } else if source != nil || preserved != nil {
        throw invalid("an unexpected managed saved-state directory appeared during display repair")
      }
    } else if intent.preservesManagedSavedState == true {
      throw invalid("managed saved-state preservation authority is missing")
    }
  }

  private static func makePlan(
    original: Data, selectedIndex: Int, hasSavedState: Bool, hasManagedSavedState: Bool = false,
    savedStateIdentity: String? = nil, managedSavedStateIdentity: String? = nil, repairedAt: String
  ) throws -> (bytes: Data, receipt: DoryVZMacDisplayRepairReceipt) {
    guard !original.isEmpty, original.count <= DoryVZMacMachineBundle.maximumManifestBytes,
      var object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
      object["schema"] as? String == DoryVZMacMachineManifest.schema,
      var resources = object["resources"] as? [String: Any],
      let displays = resources["displays"] as? [[String: Any]],
      displays.count > DoryVZMacResourcePlan.maximumDisplayCount,
      displays.indices.contains(selectedIndex),
      let rawState = object["installationState"] as? String,
      let previous = DoryVZMacMachineInstallationState(rawValue: rawState)
    else { throw invalid("manifest is not an eligible persisted multi-display definition") }
    let hasRAM = hasSavedState || hasManagedSavedState
    if previous == .suspended && !hasRAM { throw invalid("suspended RAM image is missing") }
    if hasRAM && [.prepared, .installing, .installFailed].contains(previous) {
      throw invalid("installation state cannot own a suspended RAM image")
    }
    resources["displays"] = [displays[selectedIndex]]
    object["resources"] = resources
    if hasRAM || [.suspending, .restoring].contains(previous) {
      object["installationState"] = DoryVZMacMachineInstallationState.stopped.rawValue
    }
    let bytes = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ) + Data("\n".utf8)
    guard bytes.count <= DoryVZMacMachineBundle.maximumManifestBytes else {
      throw invalid("repaired manifest exceeds the size limit")
    }
    let manifest = try JSONDecoder().decode(DoryVZMacMachineManifest.self, from: bytes)
    try manifest.validate()
    let receipt = DoryVZMacDisplayRepairReceipt(
      schema: DoryVZMacDisplayRepairReceipt.schema, repairedAt: repairedAt,
      originalDisplayCount: displays.count, selectedDisplayIndex: selectedIndex,
      selectedDisplay: manifest.resources.displays[0], previousInstallationState: previous,
      repairedInstallationState: manifest.installationState,
      originalManifestSHA256: digest(original), repairedManifestSHA256: digest(bytes),
      originalManifestBackupName: DoryVZMacMachineBundle.preDisplayRepairManifestName,
      preservedSavedStateName: hasSavedState ? DoryVZMacMachineBundle.incompatibleSavedStateName : nil,
      preservedManagedSavedStateName: hasManagedSavedState ? DoryVZMacMachineBundle.incompatibleManagedSavedStateName : nil,
      preservedSavedStateIdentity: savedStateIdentity,
      preservedManagedSavedStateIdentity: managedSavedStateIdentity
    )
    return (bytes, receipt)
  }

  private static func synchronizeDirectory(
    _ descriptor: Int32, barrier: URL, barrierDescriptor: Int32? = nil,
    io: DoryVZMacMetadataFile.WriteIO
  ) throws {
    let fileFD = open(barrier.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fileFD >= 0 else { throw failure("open display repair barrier") }
    defer { close(fileFD) }
    // read() has already checked the private, bounded intent. Pin its current named inode
    // again before asking it to drain this directory's preceding writes.
    var information = stat()
    guard fstat(fileFD, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
      information.st_uid == geteuid(), information.st_nlink == 1, information.st_mode & 0o022 == 0,
      let named = try entry(barrierDescriptor ?? descriptor, barrier.lastPathComponent), Identity(named) == Identity(information)
    else { throw invalid("display repair barrier was replaced") }
    try synchronize(descriptor, kind: .directory, io: io)
    try synchronize(fileFD, kind: .drive, io: io)
  }

  /// Reads only known, verifiable repair evidence. Neither listing nor preview creates a
  /// lease, writes a journal, renames RAM, or changes boot admission.
  static func inspect(
    at root: URL, preserveManagedSavedState: Bool = false
  ) throws -> DoryVZMacDisplayRepairAssessment? {
    guard root.isFileURL, !root.path.contains("\0") else { throw invalid("nonlocal repair root") }
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure("open display repair inspection root") }
    defer { close(descriptor) }
    var information = stat()
    guard fstat(descriptor, &information) == 0 else { throw failure("inspect display repair root") }
    try requireOwnedDirectory(information)
    let managed = try openManagedParent(root, enabled: preserveManagedSavedState)
    defer { if let managed { close(managed) } }
    let original: Data
    let plan: (bytes: Data, receipt: DoryVZMacDisplayRepairReceipt)
    let selected: Int?
    let completed: Bool
    if let bytes = try DoryVZMacMetadataFile.readIfPresent(
      from: file(root, DoryVZMacMachineBundle.displayRepairJournalName), maximumBytes: maximumIntentBytes
    ) {
      let intent = try JSONDecoder().decode(Intent.self, from: bytes)
      try validate(intent)
      guard (intent.preservesManagedSavedState ?? false) == preserveManagedSavedState else {
        throw invalid("inspection must retain the recorded managed saved-state preservation choice")
      }
      try validateCurrent(intent, at: root, descriptor: descriptor, managedDescriptor: managed)
      original = intent.original
      plan = (intent.repaired, intent.receipt)
      selected = intent.receipt.selectedDisplayIndex
      completed = false
    } else {
      let backup = try DoryVZMacMetadataFile.readIfPresent(
        from: file(root, DoryVZMacMachineBundle.preDisplayRepairManifestName))
      let current = try DoryVZMacMetadataFile.read(from: file(root, DoryVZMacMachineBundle.manifestName))
      let receiptData = try DoryVZMacMetadataFile.readIfPresent(
        from: file(root, DoryVZMacMachineBundle.displayRepairReceiptName))
      if let receiptData {
        let receipt = try JSONDecoder().decode(DoryVZMacDisplayRepairReceipt.self, from: receiptData)
        guard receipt.schema == DoryVZMacDisplayRepairReceipt.schema, let backup,
          receipt.preservedManagedSavedStateName == nil || preserveManagedSavedState else {
          throw invalid("completed display repair has no verifiable original authority")
        }
        let expected = try makePlan(original: backup, selectedIndex: receipt.selectedDisplayIndex,
          hasSavedState: receipt.preservedSavedStateName != nil,
          hasManagedSavedState: receipt.preservedManagedSavedStateName != nil,
          savedStateIdentity: receipt.preservedSavedStateIdentity == nil ? nil : identityName(try stateIdentity(descriptor, DoryVZMacMachineBundle.incompatibleSavedStateName)),
          managedSavedStateIdentity: receipt.preservedManagedSavedStateIdentity == nil ? nil
            : identityName(try managed.flatMap { try stateIdentity($0, DoryVZMacMachineBundle.incompatibleManagedSavedStateName) }),
          repairedAt: receipt.repairedAt)
        guard receipt == expected.receipt, current == expected.bytes,
          try stateIdentity(descriptor, DoryVZMacMachineBundle.suspendedStateDirectoryName) == nil,
          (try stateIdentity(descriptor, DoryVZMacMachineBundle.incompatibleSavedStateName) != nil)
            == (receipt.preservedSavedStateName != nil) else {
          throw invalid("completed display repair artifacts differ from its receipt")
        }
        if let managed {
          guard try stateIdentity(managed, DoryVZMacMachineBundle.managedSavedStateName) == nil,
            (try stateIdentity(managed, DoryVZMacMachineBundle.incompatibleManagedSavedStateName) != nil)
              == (receipt.preservedManagedSavedStateName != nil) else {
            throw invalid("completed managed saved-state preservation differs from its receipt")
          }
        }
        original = backup; plan = expected; selected = receipt.selectedDisplayIndex; completed = true
      } else {
        guard let object = try JSONSerialization.jsonObject(with: current) as? [String: Any],
          let resources = object["resources"] as? [String: Any], let displays = resources["displays"] as? [Any] else {
          throw invalid("manifest cannot be inspected for display repair")
        }
        if displays.count <= DoryVZMacResourcePlan.maximumDisplayCount {
          // A backup without its intent/receipt is not proof that a one-display manifest
          // completed this repair. Ordinary load remains the only admission for this case.
          guard backup == nil else { throw invalid("display repair completion evidence is missing") }
          return nil
        }
        guard backup == nil || backup == current else { throw invalid("display repair backup differs from the source") }
        let source = try stateIdentity(descriptor, DoryVZMacMachineBundle.suspendedStateDirectoryName)
        let preserved = try stateIdentity(descriptor, DoryVZMacMachineBundle.incompatibleSavedStateName)
        guard source == nil || preserved == nil, preserved == nil || backup != nil else {
          throw invalid("conflicting saved-state preservation artifacts")
        }
        let managedState = try managedStateIdentity(managed, backupExists: backup != nil)
        original = current
        plan = try makePlan(original: current, selectedIndex: 0, hasSavedState: (source ?? preserved) != nil,
          hasManagedSavedState: managedState != nil, repairedAt: ISO8601DateFormatter().string(from: Date()))
        selected = nil; completed = false
      }
    }
    let object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
    guard let resources = object?["resources"] as? [String: Any], let rawDisplays = resources["displays"] else {
      throw invalid("original display topology cannot be decoded")
    }
    let displays = try JSONDecoder().decode([DoryVZMacDisplay].self, from: JSONSerialization.data(withJSONObject: rawDisplays))
    guard (2...8).contains(displays.count) else { throw invalid("unsupported legacy display count") }
    // Validate every offered choice, not just the first one shown by the app.
    for index in displays.indices {
      _ = try makePlan(original: original, selectedIndex: index,
        hasSavedState: plan.receipt.preservedSavedStateName != nil,
        hasManagedSavedState: plan.receipt.preservedManagedSavedStateName != nil,
        repairedAt: plan.receipt.repairedAt)
    }
    try validateRoot(root, identity: Identity(information))
    if let managed { try validateManagedParent(root, descriptor: managed) }
    return DoryVZMacDisplayRepairAssessment(
      originalManifestSHA256: digest(original), displays: displays, pendingSelectedDisplayIndex: selected,
      preservesSavedState: plan.receipt.preservedSavedStateName != nil || plan.receipt.preservedManagedSavedStateName != nil,
      bundleRepairCompleted: completed,
      candidateManifest: try JSONDecoder().decode(DoryVZMacMachineManifest.self, from: plan.bytes))
  }

  private static func openManagedParent(_ root: URL, enabled: Bool) throws -> Int32? {
    guard enabled else { return nil }
    let descriptor = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw failure("open managed saved-state parent") }
    do { try validateManagedParent(root, descriptor: descriptor) }
    catch { close(descriptor); throw error }
    return descriptor
  }

  private static func validateManagedParent(_ root: URL, descriptor: Int32) throws {
    var held = stat(), named = stat(), bundle = stat()
    guard fstat(descriptor, &held) == 0, lstat(root.deletingLastPathComponent().path, &named) == 0,
      Identity(held) == Identity(named),
      let child = try entry(descriptor, root.lastPathComponent), lstat(root.path, &bundle) == 0,
      Identity(child) == Identity(bundle), bundle.st_mode & S_IFMT == S_IFDIR else {
      throw invalid("managed saved-state parent or bundle directory changed")
    }
    try requireOwnedDirectory(held)
  }

  private static func managedStateIdentity(_ descriptor: Int32?, backupExists: Bool) throws -> Identity? {
    guard let descriptor else { return nil }
    let source = try stateIdentity(descriptor, DoryVZMacMachineBundle.managedSavedStateName)
    let preserved = try stateIdentity(descriptor, DoryVZMacMachineBundle.incompatibleManagedSavedStateName)
    guard source == nil || preserved == nil, preserved == nil || backupExists else {
      throw invalid("managed saved-state preservation has conflicting or unowned artifacts")
    }
    return source ?? preserved
  }

  private static func synchronize(
    _ descriptor: Int32, kind: DoryVZMacMetadataFile.SyncKind, io: DoryVZMacMetadataFile.WriteIO
  ) throws {
    while io.sync(descriptor, kind) != 0 {
      if errno == EINTR { continue }
      throw failure("synchronize display repair \(kind)")
    }
  }

  private static func stateIdentity(_ descriptor: Int32, _ name: String) throws -> Identity? {
    guard let value = try entry(descriptor, name) else { return nil }
    try requireOwnedDirectory(value)
    return Identity(value)
  }

  private static func identityName(_ identity: Identity?) -> String? {
    identity.map { "\($0.device):\($0.inode)" }
  }

  private static func entry(_ descriptor: Int32, _ name: String) throws -> stat? {
    var value = stat()
    guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw failure("inspect display repair entry")
    }
    return value
  }

  private static func validateRoot(_ root: URL, identity: Identity) throws {
    var value = stat()
    guard lstat(root.path, &value) == 0, Identity(value) == identity else {
      throw invalid("display repair root changed")
    }
    try requireOwnedDirectory(value)
  }

  private static func requireOwnedDirectory(_ value: stat) throws {
    guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o022 == 0
    else { throw invalid("display repair directory is not owned and protected") }
  }

  private static func file(_ root: URL, _ name: String) -> URL {
    root.appendingPathComponent(name, isDirectory: false)
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data("\n".utf8)
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func invalid(_ detail: String) -> DoryVZMacMachineBundleError { .invalidBundle(detail) }
  private static func failure(_ operation: String) -> DoryVZMacMachineBundleError { .filesystem(operation, errno) }
}
