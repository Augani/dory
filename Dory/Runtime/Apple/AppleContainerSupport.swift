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
    enum Issue: Equatable, Sendable {
        case none
        case osVersion
        case architecture
        case missingToolchain
    }

    var isSupported: Bool
    var reason: String
    var issue: Issue = .none

    static let supported = RuntimeSupport(isSupported: true, reason: "")

    static func unsupported(_ reason: String, issue: Issue = .none) -> RuntimeSupport {
        RuntimeSupport(isSupported: false, reason: reason, issue: issue)
    }
}

/// Dory's own VMM (`dory-hv`) runs on Hypervisor.framework's in-kernel GICv3, which is available
/// from macOS 15, and needs no Apple `container` toolchain (it ships its own kernel + userspace
/// networking). So when the dory-hv engine is present it supports a strictly broader set of hosts
/// than the Virtualization.framework / Apple-container path.
enum DoryHVSupport {
    nonisolated static let minimumMajorVersion = 15

    nonisolated static func evaluate(platform: MacHostPlatform) -> RuntimeSupport {
        guard platform.isAppleSilicon else {
            return .unsupported("Dory's engine requires Apple silicon", issue: .architecture)
        }
        guard platform.major >= minimumMajorVersion else {
            return .unsupported("Dory's engine requires macOS 15 or later", issue: .osVersion)
        }
        return .supported
    }
}
