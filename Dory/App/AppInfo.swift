import Foundation

/// The app's own version and build, read from the bundle (driven by the project's
/// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) so the displayed version is always correct.
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    /// Build scripts set this explicitly. Defaulting to true keeps direct Xcode and test builds useful.
    static let includesDesktopLinux = desktopLinuxIncluded(
        from: Bundle.main.object(forInfoDictionaryKey: "DoryIncludesDesktopLinux")
    )

    static func desktopLinuxIncluded(from bundleValue: Any?) -> Bool {
        if let value = bundleValue as? Bool {
            return value
        }
        if let value = bundleValue as? NSNumber {
            return value.boolValue
        }
        return true
    }
}
