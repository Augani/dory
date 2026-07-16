import DoryOperations
import Foundation

/// The app's own version and build, read from the bundle (driven by the project's
/// `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) so the displayed version is always correct.
nonisolated enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static var componentCatalogURL: URL {
        if let override = ProcessInfo.processInfo.environment["DORY_COMPONENT_CATALOG_URL"],
           let url = URL(string: override),
           url.scheme == "https" || url.isFileURL {
            return url
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "DoryComponentCatalogURL") as? String,
           let url = URL(string: value),
           url.scheme == "https" {
            return url
        }
        return DoryComponentDefaults.catalogURL
    }
    /// Legacy 0.3.x builds used one Desktop boolean. New builds declare every payload in
    /// DoryBundledComponents; optional installed components are resolved from the selected data drive.
    static var includesDesktopLinux: Bool {
        componentAvailable(.linuxDesktop)
            && [.desktopDebian, .desktopUbuntu, .desktopKali].contains(where: componentAvailable)
    }

    static func componentAvailable(_ id: DoryComponentID) -> Bool {
        if bundledComponents.contains(id) { return true }
        guard id.isRemovable, let store = try? DoryComponentStore.selected() else { return false }
        return store.isInstalledAndValid(id)
    }

    static var bundledComponents: Set<DoryComponentID> {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "DoryBundledComponents") as? [String] {
            return Set(raw.compactMap(DoryComponentID.init(rawValue:))).union([.dockerCore])
        }
        var legacy: Set<DoryComponentID> = [.dockerCore, .kubernetes, .linuxMachines]
        if desktopLinuxIncluded(from: Bundle.main.object(forInfoDictionaryKey: "DoryIncludesDesktopLinux")) {
            legacy.formUnion([.linuxDesktop, .desktopDebian, .desktopUbuntu, .desktopKali])
        }
        return legacy
    }

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
