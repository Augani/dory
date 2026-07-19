import AppKit
import CryptoKit
import Darwin
import DoryOperations
import Security
import Sparkle

@MainActor
final class DoryUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = DoryUpdater()

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: releaseInterruptionGateFeedURL == nil,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var releaseGateUpdater: SPUUpdater?
    private var releaseGateUserDriver: DoryReleaseUpgradeUserDriver?
    private weak var store: AppStore?
    private var pendingCandidate: DoryUpgradeCandidate?
    private var preparationTask: Task<Void, Never>?

    var updater: SPUUpdater { releaseGateUpdater ?? updaterController.updater }

    private override init() {
        super.init()
        _ = updaterController
    }

    func configure(store: AppStore) {
        self.store = store
        configureReleaseGateUpdaterIfRequested()
        resumePendingTransactionWhenReady()
        runReleaseInterruptionGateWhenRequested(store: store)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        releaseInterruptionGateFeedURL?.absoluteString
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let candidate = try Self.candidate(updateItem)
        try candidate.validate()
        pendingCandidate = candidate
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard preparationTask == nil else { return true }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let store else {
                    throw DoryUpgradeError.invalidState("the app runtime is not configured")
                }
                let candidate: DoryUpgradeCandidate
                if let pendingCandidate {
                    candidate = pendingCandidate
                } else {
                    candidate = try Self.candidate(item)
                }
                let transactionStore = try DoryUpgradeTransactionStore()
                let input = try await store.upgradePreflightInput(candidate: candidate)
                var record = try await Task.detached(priority: .utility) {
                    try transactionStore.begin(input)
                }.value
                record = try transactionStore.advance(record.id, to: .snapshotting)

                let appSnapshot = try await Task.detached(priority: .utility) {
                    try DoryAppSnapshotter.captureLastGoodApp(
                        transactionID: record.id,
                        store: transactionStore
                    )
                }.value
                _ = try transactionStore.attachAppSnapshot(record.id, snapshot: appSnapshot)
                UserDefaults.standard.synchronize()
                _ = try transactionStore.captureConfiguration(record.id)
                try await store.prepareUpgradeDataAndMarker(record: record, transactionStore: transactionStore)
                try transactionStore.validateReadyToInstall(record.id)
                _ = try transactionStore.advance(record.id, to: .readyToInstall)
                // Arm the durable journal before handing control back to Sparkle. Sparkle's
                // will-install callback has no cancellation path, so relying on that callback to
                // create the installing state could leave a newly replaced app with no recovery
                // transaction if the final journal write failed.
                _ = try transactionStore.advance(record.id, to: .installing)
                preparationTask = nil
                installHandler()
            } catch {
                preparationTask = nil
                await failPreparation(error)
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        do {
            let transactionStore = try DoryUpgradeTransactionStore()
            guard let record = try transactionStore.latestNonterminal(), record.state == .installing else {
                throw DoryUpgradeError.invalidState("Sparkle reached installation without a complete last-good snapshot")
            }
            _ = try transactionStore.markArchiveValidated(record.id)
        } catch {
            presentFailure(
                title: "Update transaction could not be armed",
                message: "Dory will not treat this installation as recoverable: \(error)"
            )
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        do {
            let transactionStore = try DoryUpgradeTransactionStore()
            if let record = try transactionStore.latestNonterminal(),
               [.preflight, .snapshotting, .readyToInstall, .installing].contains(record.state),
               AppInfo.build != record.candidate.build {
                _ = try transactionStore.advance(record.id, to: .failed, error: "Sparkle aborted: \(error)")
                Task { [weak store] in await store?.removeUpgradeMarker(record) }
            }
        } catch {
            // Sparkle surfaces its own abort. A journal failure is retained for the next launch.
        }
    }

    private func resumePendingTransactionWhenReady() {
        Task { [weak self] in
            guard let self, let store else { return }
            do {
                let transactionStore = try DoryUpgradeTransactionStore()
                guard var record = try transactionStore.latestNonterminal(),
                      record.state == .installing,
                      record.candidate.build == AppInfo.build else { return }
                try? await Task.sleep(for: .seconds(2))
                record = try transactionStore.advance(record.id, to: .smokeTesting)
                var checks = [
                    DoryUpgradeSmokeCheck(
                        id: "archive.signature",
                        passed: record.candidate.archiveSignatureValidated,
                        detail: record.candidate.archiveSignatureValidated
                            ? "Sparkle validated the downloaded archive signature"
                            : "Sparkle did not persist archive-signature validation before replacement"
                    ),
                    try DoryAppSnapshotter.currentAppSmokeCheck(record: record),
                ]
                checks.append(contentsOf: await store.runUpgradeSmokeTests(record))
                record = try transactionStore.recordSmoke(record.id, checks: checks)
                let failed = checks.filter { $0.required && !$0.passed }
                if failed.isEmpty {
                    _ = try transactionStore.advance(record.id, to: .succeeded)
                    await store.removeUpgradeMarker(record)
                    return
                }

                let summary = failed.map { "\($0.id): \($0.detail)" }.joined(separator: "; ")
                record = try transactionStore.advance(record.id, to: .rollingBack, error: summary)
                guard record.rollbackSafe else {
                    let recovery = try transactionStore.exportRecovery(record.id, reason: summary)
                    _ = try transactionStore.advance(record.id, to: .recoveryRequired, error: summary)
                    presentFailure(
                        title: "Update needs data recovery",
                        message: "Post-update checks failed, but the prior app cannot safely read data schema \(record.candidate.schema.targetDataSchema). Dory did not downgrade durable data. Recovery evidence is at \(recovery)."
                    )
                    return
                }
                try DoryUpgradeRollbackHelper.launch(transactionID: record.id)
                NSApp.terminate(nil)
            } catch {
                if let transactionStore = try? DoryUpgradeTransactionStore(),
                   let record = try? transactionStore.latestNonterminal(),
                   record.state == .rollingBack {
                    let reason = "automatic rollback could not start: \(error)"
                    _ = try? transactionStore.exportRecovery(record.id, reason: reason)
                    _ = try? transactionStore.advance(record.id, to: .recoveryRequired, error: reason)
                }
                presentFailure(
                    title: "Update verification could not finish",
                    message: "Dory retained the upgrade journal and verified data snapshot: \(error)"
                )
            }
        }
    }

    private var releaseInterruptionGateFeedURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DORY_RELEASE_UPGRADE_GATE"] == "INTERRUPT-LAST-GOOD-ROLLBACK",
              let raw = environment["DORY_RELEASE_UPGRADE_FEED_URL"],
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              ["127.0.0.1", "::1"].contains(url.host ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func configureReleaseGateUpdaterIfRequested() {
        guard releaseGateUpdater == nil, releaseInterruptionGateFeedURL != nil else { return }
        let userDriver = DoryReleaseUpgradeUserDriver()
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self
        )
        do {
            try updater.start()
            releaseGateUserDriver = userDriver
            releaseGateUpdater = updater
        } catch {
            presentFailure(title: "Release upgrade gate could not start Sparkle", message: "\(error)")
        }
    }

    private func runReleaseInterruptionGateWhenRequested(store: AppStore) {
        guard releaseInterruptionGateFeedURL != nil else { return }
        Task { [weak self, weak store] in
            guard let self, let store else { return }
            for _ in 0..<240 {
                if store.loadState == .ready, store.dorydRuntimeActive {
                    if self.releaseInterruptionGateIsArmed {
                        self.checkForUpdates()
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self.presentFailure(
                title: "Release upgrade gate could not start",
                message: "Dory's managed engine did not become ready within 120 seconds."
            )
        }
    }

    private var releaseInterruptionGateIsArmed: Bool {
        guard releaseInterruptionGateFeedURL != nil,
              let path = ProcessInfo.processInfo.environment["DORY_RELEASE_UPGRADE_ARM_FILE"],
              path.hasPrefix("/"), path != "/" else { return false }
        var status = stat()
        return lstat(path, &status) == 0
            && (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == getuid()
            && status.st_nlink == 1
            && status.st_mode & 0o077 == 0
            && status.st_size == 0
    }

    private func failPreparation(_ error: Error) async {
        do {
            let transactionStore = try DoryUpgradeTransactionStore()
            if let record = try transactionStore.latestNonterminal(),
               [.preflight, .snapshotting, .readyToInstall].contains(record.state) {
                _ = try transactionStore.advance(record.id, to: .failed, error: "pre-install snapshot failed: \(error)")
                await store?.removeUpgradeMarker(record)
            }
        } catch {
            // The primary error is more useful to the user; the journal remains fail-closed.
        }
        presentFailure(
            title: "Update was not installed",
            message: "Dory could not create and verify the required last-good snapshot: \(error)"
        )
    }

    private func presentFailure(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func candidate(_ item: SUAppcastItem) throws -> DoryUpgradeCandidate {
        func integer(_ key: String) throws -> Int {
            let raw = item.propertiesDictionary[key]
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String, let parsed = Int(value) { return parsed }
            throw DoryUpgradeError.invalidCandidate("appcast item is missing integer \(key)")
        }
        let currentSchema = DoryDataDrive.schemaVersion
        let priorMinimum = Bundle.main.object(forInfoDictionaryKey: "DoryMinimumReadableDataSchema") as? Int
            ?? currentSchema
        let priorMaximum = Bundle.main.object(forInfoDictionaryKey: "DoryMaximumReadableDataSchema") as? Int
            ?? currentSchema
        guard let source = item.fileURL?.absoluteString else {
            throw DoryUpgradeError.invalidCandidate("update enclosure has no URL")
        }
        guard item.signingValidationStatus != .failed,
              let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any],
              let signatureText = enclosure["sparkle:edSignature"] as? String,
              let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
            throw DoryUpgradeError.invalidCandidate("update enclosure has no valid Ed25519 signature declaration")
        }
        return DoryUpgradeCandidate(
            version: item.displayVersionString,
            build: item.versionString,
            sourceURL: source,
            downloadBytes: item.contentLength,
            installationType: item.installationType,
            enclosureSignatureDeclared: true,
            componentCatalogSchema: try integer("dory:componentCatalogSchema"),
            schema: DoryUpgradeSchemaContract(
                currentDataSchema: currentSchema,
                targetDataSchema: try integer("dory:dataSchemaVersion"),
                candidateMinimumReadableSchema: try integer("dory:minimumReadableDataSchema"),
                candidateMaximumReadableSchema: try integer("dory:maximumReadableDataSchema"),
                priorMinimumReadableSchema: priorMinimum,
                priorMaximumReadableSchema: priorMaximum
            )
        )
    }
}

/// Non-interactive Sparkle UI used only by the signature-bound physical release interruption gate.
/// Production update checks continue to use Sparkle's standard user driver.
@MainActor
private final class DoryReleaseUpgradeUserDriver: NSObject, SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        reply(appcastItem.isInformationOnlyUpdate ? .dismiss : .install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { reply(.install) }
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}

nonisolated private enum DoryAppSnapshotter {
    private struct Identity {
        var teamIdentifier: String
        var designatedRequirement: String
        var executableSHA256: String
        var version: String
        var build: String
    }

    static func captureLastGoodApp(
        transactionID: UUID,
        store: DoryUpgradeTransactionStore
    ) throws -> DoryUpgradeAppSnapshot {
        let source = Bundle.main.bundleURL.path
        let sourceIdentity = try inspect(bundlePath: source)
        let destination = store.appBackupPath(transactionID)
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw DoryUpgradeError.invalidSnapshot("last-good app destination already exists")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-cR", source, destination]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: destination)
            throw DoryUpgradeError.filesystem("clone last-good Dory.app failed with status \(process.terminationStatus)")
        }
        let copiedIdentity = try inspect(bundlePath: destination)
        guard copiedIdentity.teamIdentifier == sourceIdentity.teamIdentifier,
              copiedIdentity.designatedRequirement == sourceIdentity.designatedRequirement,
              copiedIdentity.executableSHA256 == sourceIdentity.executableSHA256,
              copiedIdentity.version == sourceIdentity.version,
              copiedIdentity.build == sourceIdentity.build else {
            try? FileManager.default.removeItem(atPath: destination)
            throw DoryUpgradeError.invalidSnapshot("copied app identity differs from the running app")
        }
        return DoryUpgradeAppSnapshot(
            bundlePath: source,
            backupPath: destination,
            version: sourceIdentity.version,
            build: sourceIdentity.build,
            executableSHA256: sourceIdentity.executableSHA256,
            teamIdentifier: sourceIdentity.teamIdentifier,
            designatedRequirement: sourceIdentity.designatedRequirement
        )
    }

    static func currentAppSmokeCheck(record: DoryUpgradeTransactionRecord) throws -> DoryUpgradeSmokeCheck {
        let current = try inspect(bundlePath: Bundle.main.bundleURL.path)
        let prior = try record.appSnapshot.unwrap("last-good app identity is missing")
        let passed = current.build == record.candidate.build
            && current.version == record.candidate.version
            && current.teamIdentifier == prior.teamIdentifier
            && current.designatedRequirement == prior.designatedRequirement
        return DoryUpgradeSmokeCheck(
            id: "app.identity",
            passed: passed,
            detail: "running=\(current.version)(\(current.build)) team=\(current.teamIdentifier); expected=\(record.candidate.version)(\(record.candidate.build)) team=\(prior.teamIdentifier)"
        )
    }

    static func validateRollbackBundle(_ snapshot: DoryUpgradeAppSnapshot, at path: String) throws {
        let identity = try inspect(bundlePath: path)
        guard identity.version == snapshot.version,
              identity.build == snapshot.build,
              identity.teamIdentifier == snapshot.teamIdentifier,
              identity.designatedRequirement == snapshot.designatedRequirement,
              identity.executableSHA256 == snapshot.executableSHA256 else {
            throw DoryUpgradeError.invalidSnapshot("rollback application identity mismatch")
        }
    }

    private static func inspect(bundlePath: String) throws -> Identity {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard let bundle = Bundle(url: bundleURL),
              let executable = bundle.executableURL,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw DoryUpgradeError.invalidSnapshot("application bundle metadata at \(bundlePath)")
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw DoryUpgradeError.invalidSnapshot("application code signature at \(bundlePath)")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any],
        let team = values[kSecCodeInfoTeamIdentifier] as? String,
        !team.isEmpty else {
            throw DoryUpgradeError.invalidSnapshot("application has no production team identity")
        }
        var requirement: SecRequirement?
        var requirementText: CFString?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, SecCSFlags(), &requirementText) == errSecSuccess,
              let requirementText else {
            throw DoryUpgradeError.invalidSnapshot("application designated requirement")
        }
        let executableData = try Data(contentsOf: executable, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: executableData).map { String(format: "%02x", $0) }.joined()
        return Identity(
            teamIdentifier: team,
            designatedRequirement: requirementText as String,
            executableSHA256: digest,
            version: version,
            build: build
        )
    }
}

nonisolated enum DoryUpgradeRollbackHelper {
    static let argument = "--dory-upgrade-rollback"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.count == 4, arguments[1] == argument,
              let id = UUID(uuidString: arguments[2]),
              let parentPID = Int32(arguments[3]), parentPID > 1 else { return }
        do {
            try run(transactionID: id, parentPID: parentPID)
            exit(EXIT_SUCCESS)
        } catch {
            if let store = try? DoryUpgradeTransactionStore(),
               let record = try? store.load(id) {
                _ = try? store.exportRecovery(id, reason: "automatic app rollback failed: \(error)")
                _ = try? store.advance(id, to: .recoveryRequired, error: "automatic app rollback failed: \(error)")
                relaunch(path: record.appSnapshot?.bundlePath ?? Bundle.main.bundleURL.path)
            }
            exit(70)
        }
    }

    @MainActor static func launch(transactionID: UUID) throws {
        guard let executable = Bundle.main.executableURL else {
            throw DoryUpgradeError.invalidSnapshot("running app executable")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, transactionID.uuidString.lowercased(), String(getpid())]
        try process.run()
    }

    private static func run(transactionID: UUID, parentPID: Int32) throws {
        let store = try DoryUpgradeTransactionStore()
        let record = try store.load(transactionID)
        guard record.state == .rollingBack,
              let snapshot = record.appSnapshot else {
            throw DoryUpgradeError.invalidState("rollback helper was not armed")
        }
        try DoryAppSnapshotter.validateRollbackBundle(snapshot, at: snapshot.backupPath)
        let deadline = Date().addingTimeInterval(120)
        while kill(parentPID, 0) == 0, Date() < deadline { usleep(100_000) }
        guard kill(parentPID, 0) != 0, errno == ESRCH else {
            throw DoryUpgradeError.invalidState("updated app did not terminate before rollback")
        }
        // Restore preferences only after the failed app has exited so its UserDefaults process
        // cannot flush candidate settings over the last-good snapshot during termination.
        try store.restoreConfigurationAndComponents(transactionID)

        let current = snapshot.bundlePath
        let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
        let stage = parent + "/.Dory.rollback-\(transactionID.uuidString.lowercased()).app"
        let failed = parent + "/.Dory.failed-\(transactionID.uuidString.lowercased()).app"
        guard !FileManager.default.fileExists(atPath: stage),
              !FileManager.default.fileExists(atPath: failed) else {
            throw DoryUpgradeError.unsafePath(stage)
        }
        try FileManager.default.copyItem(atPath: snapshot.backupPath, toPath: stage)
        try DoryAppSnapshotter.validateRollbackBundle(snapshot, at: stage)
        guard rename(current, failed) == 0 else {
            try? FileManager.default.removeItem(atPath: stage)
            throw DoryUpgradeError.filesystem("stage failed app for rollback: errno \(errno)")
        }
        guard rename(stage, current) == 0 else {
            let publishError = errno
            _ = rename(failed, current)
            throw DoryUpgradeError.filesystem("publish last-good app: errno \(publishError)")
        }
        try DoryAppSnapshotter.validateRollbackBundle(snapshot, at: current)
        _ = try store.advance(transactionID, to: .rolledBack)
        try? FileManager.default.removeItem(atPath: failed)
        relaunch(path: current)
    }

    private static func relaunch(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        try? process.run()
    }
}

nonisolated private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw DoryUpgradeError.invalidSnapshot(message) }
        return self
    }
}
