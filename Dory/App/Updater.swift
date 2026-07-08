import AppKit
import Sparkle

@MainActor
final class DoryUpdater {
    static let shared = DoryUpdater()

    private let updaterController: SPUStandardUpdaterController

    var updater: SPUUpdater { updaterController.updater }

    private init(startingUpdater: Bool = true) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
}
