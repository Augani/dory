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

    init(id: String, imageRef: String, machineName: String, note: String, createdISO: String,
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
