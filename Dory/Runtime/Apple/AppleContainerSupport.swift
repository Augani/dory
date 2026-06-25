import Darwin
import Foundation

nonisolated struct MacHostPlatform: Equatable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int
    var architecture: String

    var isAppleSilicon: Bool {
        architecture == "arm64" || architecture == "arm64e"
    }

    static func current() -> MacHostPlatform {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return MacHostPlatform(
            major: version.majorVersion,
            minor: version.minorVersion,
            patch: version.patchVersion,
            architecture: currentArchitecture()
        )
    }

    private static func currentArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        var machine = systemInfo.machine
        return withUnsafePointer(to: &machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: systemInfo.machine)) {
                String(cString: $0)
            }
        }
    }
}

nonisolated struct RuntimeSupport: Equatable, Sendable {
    var isSupported: Bool
    var reason: String

    static let supported = RuntimeSupport(isSupported: true, reason: "")

    static func unsupported(_ reason: String) -> RuntimeSupport {
        RuntimeSupport(isSupported: false, reason: reason)
    }
}

enum AppleContainerSupport {
    nonisolated static let minimumMajorVersion = 26

    nonisolated static func evaluate(platform: MacHostPlatform, hasContainerCLI: Bool) -> RuntimeSupport {
        guard platform.major >= minimumMajorVersion else {
            return .unsupported("requires macOS 26 or later for Apple's container engine")
        }
        guard platform.isAppleSilicon else {
            return .unsupported("requires Apple silicon for Apple's container engine")
        }
        guard hasContainerCLI else {
            return .unsupported("needs Apple's container toolchain")
        }
        return .supported
    }
}
