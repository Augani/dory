import Foundation

struct MachineSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let imageRef: String
    let machineName: String
    let note: String
    let createdISO: String
    let sizeBytes: Int64
    let distro: String
    let version: String
    let arch: String
    let boot: String
    let recipe: String
    let username: String
    let uid: Int?
    let homePath: String?
    let loginShell: String

    nonisolated init(id: String, imageRef: String, machineName: String, note: String, createdISO: String,
                     sizeBytes: Int64, distro: String, version: String, arch: String, boot: String,
                     recipe: String, username: String = "root", uid: Int? = nil, homePath: String? = nil,
                     loginShell: String = "/bin/sh") {
        self.id = id
        self.imageRef = imageRef
        self.machineName = machineName
        self.note = note
        self.createdISO = createdISO
        self.sizeBytes = sizeBytes
        self.distro = distro
        self.version = version
        self.arch = arch
        self.boot = boot
        self.recipe = recipe
        self.username = username
        self.uid = uid
        self.homePath = homePath
        self.loginShell = loginShell
    }
}

enum SnapshotScheduleFrequency: String, Codable, CaseIterable, Sendable {
    case hourly, daily, weekly

    var interval: TimeInterval {
        switch self {
        case .hourly: 60 * 60
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }
}

struct MachineSnapshotSchedule: Codable, Equatable, Sendable {
    var machineName: String
    var frequency: SnapshotScheduleFrequency
    var keepLocal: Int
    var s3: S3BackupDestination?

    init(machineName: String, frequency: SnapshotScheduleFrequency, keepLocal: Int = 7, s3: S3BackupDestination? = nil) {
        self.machineName = machineName
        self.frequency = frequency
        self.keepLocal = keepLocal
        self.s3 = s3
    }

    func validate() throws {
        guard !machineName.isEmpty, machineName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw SnapshotScheduleError.invalidMachineName
        }
        guard keepLocal > 0 else { throw SnapshotScheduleError.invalidRetention }
        try s3?.validate()
    }

    func isDue(lastSnapshotAt: Date?, now: Date) -> Bool {
        guard let lastSnapshotAt else { return true }
        return now.timeIntervalSince(lastSnapshotAt) >= frequency.interval
    }

    func nextRun(after lastSnapshotAt: Date?) -> Date? {
        guard let lastSnapshotAt else { return nil }
        return lastSnapshotAt.addingTimeInterval(frequency.interval)
    }
}

struct S3BackupDestination: Codable, Equatable, Sendable {
    var bucket: String
    var prefix: String
    var region: String?

    init(bucket: String, prefix: String = "", region: String? = nil) {
        self.bucket = bucket
        self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.region = region
    }

    func validate() throws {
        guard Self.isValidBucket(bucket) else { throw SnapshotScheduleError.invalidBucket }
        guard !prefix.contains("..") else { throw SnapshotScheduleError.invalidPrefix }
    }

    func objectKey(for snapshot: MachineSnapshot) -> String {
        let timestamp = snapshot.createdISO
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        let filename = "\(snapshot.machineName)-\(timestamp)-\(snapshot.id.safeSnapshotComponent).tar"
        return prefix.isEmpty ? filename : "\(prefix)/\(filename)"
    }

    func url(for snapshot: MachineSnapshot) -> String {
        "s3://\(bucket)/\(objectKey(for: snapshot))"
    }

    static func isValidBucket(_ value: String) -> Bool {
        guard (3...63).contains(value.count),
              value.first?.isLetter == true || value.first?.isNumber == true,
              value.last?.isLetter == true || value.last?.isNumber == true else {
            return false
        }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "-" }
    }
}

enum SnapshotScheduleError: Error, Equatable {
    case invalidMachineName
    case invalidRetention
    case invalidBucket
    case invalidPrefix
}

private extension String {
    var safeSnapshotComponent: String {
        let mapped = map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let value = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? "snapshot" : value
    }
}

enum SnapshotLabels {
    static let ofKey = "dory.snapshot.of"
    static let noteKey = "dory.snapshot.note"
    static let createdKey = "dory.snapshot.created"

    static func make(machine: Machine, note: String, createdISO: String) -> [String: String] {
        let family = MachineDistro.all.first { $0.display == machine.distro }?.family ?? machine.distro.lowercased()
        let boot = MachineDistro.forFamily(family)?.boot.rawValue ?? "systemd"
        var labels: [String: String] = [
            "dory.machine": family,
            "dory.machine.version": machine.version,
            "dory.machine.arch": machine.arch.isEmpty ? MachineArch.host.rawValue : machine.arch,
            "dory.machine.boot": boot,
            ofKey: machine.name,
            noteKey: note,
            createdKey: createdISO,
        ]
        if !machine.recipe.isEmpty { labels["dory.recipe"] = machine.recipe }
        if machine.username != "root" {
            labels[MachineService.userLabel] = machine.username
            labels[MachineService.shellLabel] = machine.loginShell
            if let uid = machine.uid { labels[MachineService.uidLabel] = "\(uid)" }
            if let home = machine.homePath { labels[MachineService.homeLabel] = home }
        }
        return labels
    }

    static func snapshots(fromImagesJSON data: Data) -> [MachineSnapshot] {
        struct Entry: Decodable { let Id: String; let RepoTags: [String]?; let Size: Int64?; let Labels: [String: String]? }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.compactMap { entry -> MachineSnapshot? in
            guard let labels = entry.Labels, let of = labels[ofKey] else { return nil }
            let ref = entry.RepoTags?.first(where: { $0 != "<none>:<none>" }) ?? entry.Id
            let family = labels["dory.machine"] ?? ""
            let display = MachineDistro.forFamily(family)?.display ?? family
            return MachineSnapshot(
                id: entry.Id, imageRef: ref, machineName: of,
                note: labels[noteKey] ?? "", createdISO: labels[createdKey] ?? "",
                sizeBytes: entry.Size ?? 0, distro: display,
                version: labels["dory.machine.version"] ?? "",
                arch: labels["dory.machine.arch"] ?? "",
                boot: labels["dory.machine.boot"] ?? "systemd",
                recipe: labels["dory.recipe"] ?? "",
                username: labels[MachineService.userLabel] ?? "root",
                uid: labels[MachineService.uidLabel].flatMap { Int($0) },
                homePath: labels[MachineService.homeLabel],
                loginShell: labels[MachineService.shellLabel] ?? "/bin/sh"
            )
        }
    }
}
