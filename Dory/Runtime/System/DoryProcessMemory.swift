import Foundation
#if canImport(Darwin)
import Darwin
#endif

nonisolated enum DoryProcessRole: String, Sendable, Hashable, CaseIterable {
    case app
    case daemon
    case dockerVM
    case machineVM
    case networking
    case helper

    var title: String {
        switch self {
        case .app: "Dory app"
        case .daemon: "doryd"
        case .dockerVM: "Docker VM"
        case .machineVM: "Machine VMs"
        case .networking: "Networking"
        case .helper: "Helpers"
        }
    }

    var sortOrder: Int {
        switch self {
        case .app: 0
        case .daemon: 1
        case .dockerVM: 2
        case .machineVM: 3
        case .networking: 4
        case .helper: 5
        }
    }
}

nonisolated struct DoryProcessMemoryRow: Identifiable, Sendable, Equatable {
    var role: DoryProcessRole
    var pid: Int32
    var name: String
    var residentBytes: UInt64
    var virtualBytes: UInt64
    var path: String

    var id: String { "\(pid)-\(name)" }
    var residentDisplay: String { DockerFormat.bytes(Int64(clamping: residentBytes)) }
    var virtualDisplay: String { DockerFormat.bytes(Int64(clamping: virtualBytes)) }
    var title: String { role.title }
    var subtitle: String { pid == 0 ? name : "\(name) pid \(pid)" }
}

nonisolated struct DoryProcessMemorySnapshot: Sendable, Equatable {
    var generatedAt: Date
    var rows: [DoryProcessMemoryRow]

    static let empty = DoryProcessMemorySnapshot(generatedAt: .distantPast, rows: [])

    var totalResidentBytes: UInt64 {
        rows.reduce(0) { $0 + $1.residentBytes }
    }

    var totalResidentDisplay: String {
        DockerFormat.bytes(Int64(clamping: totalResidentBytes))
    }

    var appInstanceCount: Int {
        rows.filter { $0.role == .app }.count
    }

    var duplicateAppInstanceCount: Int {
        max(0, appInstanceCount - 1)
    }

    var groupedRows: [DoryProcessMemoryRow] {
        var grouped: [DoryProcessRole: DoryProcessMemoryRow] = [:]
        for row in rows {
            var aggregate = grouped[row.role] ?? DoryProcessMemoryRow(
                role: row.role,
                pid: row.pid,
                name: row.name,
                residentBytes: 0,
                virtualBytes: 0,
                path: row.path
            )
            aggregate.residentBytes += row.residentBytes
            aggregate.virtualBytes += row.virtualBytes
            if row.role == .machineVM || grouped[row.role] != nil {
                let count = rows.filter { $0.role == row.role }.count
                aggregate.pid = 0
                aggregate.name = count == 1 ? row.name : "\(count) processes"
                aggregate.path = ""
            }
            grouped[row.role] = aggregate
        }
        return grouped.values.sorted {
            if $0.role.sortOrder == $1.role.sortOrder { return $0.name < $1.name }
            return $0.role.sortOrder < $1.role.sortOrder
        }
    }

    var sortedRows: [DoryProcessMemoryRow] {
        rows.sorted {
            if $0.role.sortOrder == $1.role.sortOrder {
                if $0.residentBytes == $1.residentBytes { return $0.pid < $1.pid }
                return $0.residentBytes > $1.residentBytes
            }
            return $0.role.sortOrder < $1.role.sortOrder
        }
    }
}

nonisolated enum DoryProcessMemorySampler {
    static func snapshot(currentPID: pid_t = getpid()) -> DoryProcessMemorySnapshot {
        snapshot(rows: processRows(currentPID: currentPID))
    }

    static func snapshot(rows: [DoryProcessMemoryRow]) -> DoryProcessMemorySnapshot {
        DoryProcessMemorySnapshot(generatedAt: Date(), rows: rows.sorted {
            if $0.role.sortOrder == $1.role.sortOrder { return $0.pid < $1.pid }
            return $0.role.sortOrder < $1.role.sortOrder
        })
    }

    static func classify(pid: pid_t, name: String, path: String, currentPID: pid_t = getpid()) -> DoryProcessRole? {
        if pid == currentPID { return .app }
        switch name {
        case "Dory":
            return path.contains("/Dory.app/Contents/MacOS/Dory") ? .app : nil
        case "doryd":
            return .daemon
        case "dory-hv":
            return .dockerVM
        case "dory-vmm":
            return .machineVM
        case "gvproxy", "dory-network-helper":
            return .networking
        case "dory", "dory-doctor", "dory-idle-proxy", "docker", "docker-buildx", "docker-compose", "kubectl":
            return isBundledHelperPath(path) ? .helper : nil
        default:
            return nil
        }
    }

    private static func isBundledHelperPath(_ path: String) -> Bool {
        path.contains("/Dory.app/Contents/Helpers/")
            || path.contains("/.dory/bin/")
    }

    private static func processRows(currentPID: pid_t) -> [DoryProcessMemoryRow] {
        #if canImport(Darwin)
        let pids = allProcessIDs()
        return pids.compactMap { pid in
            guard pid > 0 else { return nil }
            let path = processPath(pid)
            let name = processName(pid, path: path)
            guard let role = classify(pid: pid, name: name, path: path, currentPID: currentPID),
                  let info = taskInfo(pid) else { return nil }
            return DoryProcessMemoryRow(
                role: role,
                pid: pid,
                name: name,
                residentBytes: UInt64(info.pti_resident_size),
                virtualBytes: UInt64(info.pti_virtual_size),
                path: path
            )
        }
        #else
        return []
        #endif
    }

    #if canImport(Darwin)
    private static func allProcessIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: capacity)
        let usedBytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard usedBytes > 0 else { return [] }
        return Array(pids.prefix(Int(usedBytes) / MemoryLayout<pid_t>.stride))
    }

    private static func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard result > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func processName(_ pid: pid_t, path: String) -> String {
        if !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let result = buffer.withUnsafeMutableBufferPointer {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard result > 0 else { return "pid-\(pid)" }
        return String(cString: buffer)
    }

    private static func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(size))
        }
        guard result == Int32(size) else { return nil }
        return info
    }
    #endif
}
