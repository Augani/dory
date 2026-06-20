import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater so the rest of the app can trigger update checks
/// and reflect the "check automatically" preference without touching Sparkle directly.
@MainActor
final class DoryUpdater {
    static let shared = DoryUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
