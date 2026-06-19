import Foundation

/// The app's own version and build, read from the bundle (driven by the project's
/// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) so the displayed version is always correct.
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
}
