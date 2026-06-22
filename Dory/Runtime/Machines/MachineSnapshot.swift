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
}

enum SnapshotLabels {
    static let ofKey = "dory.snapshot.of"
    static let noteKey = "dory.snapshot.note"
    static let createdKey = "dory.snapshot.created"

    static func make(machine: Machine, note: String, createdISO: String) -> [String: String] {
        let family = MachineDistro.all.first { $0.display == machine.distro }?.family ?? machine.distro.lowercased()
        return [
            "dory.machine": family,
            "dory.machine.version": machine.version,
            "dory.machine.arch": machine.arch.isEmpty ? MachineArch.host.rawValue : machine.arch,
            ofKey: machine.name,
            noteKey: note,
            createdKey: createdISO,
        ]
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
                arch: labels["dory.machine.arch"] ?? ""
            )
        }
    }
}
