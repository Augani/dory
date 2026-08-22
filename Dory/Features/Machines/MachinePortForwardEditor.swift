import DoryOperations
import SwiftUI

struct MachinePortForwardDraft: Identifiable, Hashable {
    let id: UUID
    var name: String
    var transport: DoryVMPortForwardTransport
    var hostPort: String
    var guestPort: String
    var exposure: DoryVMPortForwardExposure

    init(
        id: UUID = UUID(),
        name: String = "",
        transport: DoryVMPortForwardTransport = .tcp,
        hostPort: String = "",
        guestPort: String = "",
        exposure: DoryVMPortForwardExposure = .loopback
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.exposure = exposure
    }

    init(_ forward: DoryVMPortForward) {
        self.init(
            name: forward.id,
            transport: forward.transport,
            hostPort: String(forward.hostPort),
            guestPort: String(forward.guestPort),
            exposure: forward.exposure
        )
    }

    var resolved: DoryVMPortForward? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeIdentifier(normalizedName),
              let host = UInt16(hostPort), host >= 1_024,
              let guest = UInt16(guestPort), guest > 0 else {
            return nil
        }
        return DoryVMPortForward(
            id: normalizedName,
            transport: transport,
            hostPort: host,
            guestPort: guest,
            exposure: exposure
        )
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard (1...63).contains(bytes.count), alphaNumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy {
            alphaNumeric($0) || $0 == 95 || $0 == 46 || $0 == 45
        }
    }

    static func resolved(
        _ rows: [Self],
        networkMode: DoryVMNetworkMode
    ) -> [DoryVMPortForward]? {
        guard rows.count <= DoryVMPortForward.maximumCount else { return nil }
        let forwards = rows.compactMap(\.resolved)
        guard forwards.count == rows.count,
              rows.isEmpty || networkMode == .sharedNAT || networkMode == .isolated else {
            return nil
        }
        var identifiers: Set<String> = []
        var bindings: Set<String> = []
        for forward in forwards {
            guard identifiers.insert(forward.id).inserted,
                  bindings.insert("\(forward.transport.rawValue):\(forward.hostPort)").inserted,
                  forward.exposure != .lan || networkMode == .sharedNAT else {
                return nil
            }
        }
        return forwards
    }
}

struct MachinePortForwardEditor: View {
    @Environment(\.palette) private var p
    @Binding var rows: [MachinePortForwardDraft]
    let networkMode: DoryVMNetworkMode
    let accessibilityPrefix: String

    private var isValid: Bool {
        MachinePortForwardDraft.resolved(rows, networkMode: networkMode) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PORT FORWARDS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(p.text3)
                    .tracking(0.5)
                Spacer(minLength: 0)
                Button {
                    guard rows.count < DoryVMPortForward.maximumCount else { return }
                    rows.append(MachinePortForwardDraft())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(p.accent)
                        .frame(width: 22, height: 22)
                        .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(accessibilityPrefix)-add-forward")
            }

            ForEach($rows) { $row in
                HStack(spacing: 7) {
                    TextField("name", text: $row.name)
                        .frame(width: 86)
                    Picker("Transport", selection: $row.transport) {
                        Text("TCP").tag(DoryVMPortForwardTransport.tcp)
                        Text("UDP").tag(DoryVMPortForwardTransport.udp)
                    }
                    .labelsHidden()
                    .frame(width: 68)
                    TextField("host", text: $row.hostPort)
                        .frame(width: 58)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(p.text3)
                    TextField("guest", text: $row.guestPort)
                        .frame(width: 58)
                    Picker("Exposure", selection: $row.exposure) {
                        Text("This Mac").tag(DoryVMPortForwardExposure.loopback)
                        Text("LAN").tag(DoryVMPortForwardExposure.lan)
                    }
                    .labelsHidden()
                    .frame(width: 92)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(p.text3)
                    }
                    .buttonStyle(.plain)
                }
                .textFieldStyle(.roundedBorder)
            }

            Text(rows.isEmpty
                 ? "Expose selected guest services only when you add them."
                 : isValid
                    ? "Host ports 1024–65535 are installed exactly before the VM is ready."
                    : "Use unique names and transport/host-port pairs. LAN requires Shared NAT; host ports start at 1024.")
                .font(.system(size: 11))
                .foregroundStyle(isValid ? p.text3 : p.red)
        }
    }
}
