import Foundation

struct MachineShellTarget: Hashable, Codable, Sendable {
    let machineID: String
}

struct UserFacingMachineShellTarget: Hashable, Codable, Sendable {
    let machineID: String
}

struct TerminalSession: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let subtitle: String
    let logo: String?
    let socketPath: String
    let containerID: String
    let user: String
    let shell: String
    let home: String
    var kubeExec: KubeExecTarget? = nil
    var machineShell: MachineShellTarget? = nil
}
