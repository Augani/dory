import Foundation

enum MachineArch: String, Sendable, Hashable, CaseIterable, Identifiable {
    case arm64
    case amd64

    var id: String { rawValue }
    var platform: String { "linux/\(rawValue)" }
    var shortLabel: String { rawValue }

    var display: String {
        switch self {
        case .arm64: "Apple Silicon"
        case .amd64: "Intel x86-64"
        }
    }

    nonisolated static let host: MachineArch = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return machine.hasPrefix("arm") || machine.hasPrefix("aarch") ? .arm64 : .amd64
    }()

    var isNative: Bool { self == MachineArch.host }

    func label(includeEmulated: Bool = true) -> String {
        let base = "\(display) (\(rawValue))"
        return includeEmulated && !isNative ? "\(base) · emulated" : base
    }
}
