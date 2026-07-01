import AppKit

@MainActor
final class DoryUpdater {
    static let shared = DoryUpdater()

    private init() {}

    func checkForUpdates() {
        if let url = URL(string: "https://github.com/Augani/dory/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    var automaticallyChecks: Bool {
        get { false }
        set { _ = newValue }
    }
}
