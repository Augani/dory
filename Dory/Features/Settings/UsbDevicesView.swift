import SwiftUI

struct UsbDevicesView: View {
    @Environment(\.palette) private var p
    @State private var hostDevices: [DorydHostUSBDevice] = []
    @State private var machine = UserDefaults.standard.string(forKey: "dev.dory.usb.lastMachine") ?? "default"
    @State private var busid = ""
    @State private var machines: [DorydMachineStatus] = []
    @State private var remembered: [UsbAttachment] = UsbAttachmentStore().attachments()
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            groupLabel("HOST USB")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { Task { await refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                }

                ScrollView {
                    if hostDevices.isEmpty {
                        Text("No attachable host USB devices found.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(p.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(hostDevices) { device in
                                hostDeviceButton(device)
                                if device.id != hostDevices.last?.id { Divider() }
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 280)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            }
            .padding(16)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))

            groupLabel("ATTACHMENT")
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(availabilityMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(p.text2)
                } icon: {
                    Image(systemName: attachmentIsAvailable
                        ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(attachmentIsAvailable ? .green : .orange)
                }
                .accessibilityIdentifier(attachmentIsAvailable
                    ? "usb-passthrough-available" : "usb-passthrough-unavailable")

                Text("Attach grants the selected guest temporary access to this host device. The public app requests user authorization only; it never silently seizes or captures devices.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(p.text3)

                HStack(spacing: 10) {
                    Picker("Machine", selection: $machine) {
                        if machines.isEmpty {
                            Text("No local machines").tag(machine)
                        } else {
                            ForEach(machines, id: \.id) { candidate in
                                Text("\(candidate.id)  ·  \(candidate.state)").tag(candidate.id)
                            }
                        }
                    }
                        .labelsHidden()
                        .frame(minWidth: 190)
                        .accessibilityIdentifier("usb-machine")
                    TextField("bus id", text: $busid)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityIdentifier("usb-busid")
                }

                HStack(spacing: 10) {
                    Button { Task { await attach() } } label: {
                        Label("Attach", systemImage: "cable.connector")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !attachmentIsAvailable ||
                        busy || busid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    Button { Task { await detach() } } label: {
                        Label("Detach", systemImage: "xmark.circle")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !attachmentIsAvailable ||
                        busy || busid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(p.text3)
                        .textSelection(.enabled)
                }

                if !remembered.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Legacy remembered entries (automatic replay is disabled)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(p.text3)
                        ForEach(remembered) { attachment in
                            HStack(spacing: 8) {
                                Text("\(attachment.machine)  \(attachment.busID)  port \(attachment.port)")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(p.text2)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    forget(attachment)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Forget attachment")
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
        }
        .task {
            if hostDevices.isEmpty { await refresh() }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
            .padding(.bottom, -10)
    }

    private func hostDeviceButton(_ device: DorydHostUSBDevice) -> some View {
        let subtitle = String(
            format: "%@  ·  %04x:%04x",
            device.busID,
            device.vendorID,
            device.productID
        )
        return Button {
            busid = device.busID
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(p.text)
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
                if busid == device.busID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("usb-device-\(device.busID)")
    }

    @MainActor private func refresh() async {
        busy = true
        defer { busy = false }
        async let deviceScan = DorydClient().hostUSBDevices()
        async let machineScan = DorydClient().machineList()
        var errors: [String] = []
        do {
            machines = try await machineScan.sorted { $0.id < $1.id }
            if !machines.contains(where: { $0.id == machine }) {
                machine = machines.first(where: {
                    UsbPassthroughAvailability.attachSupported(for: $0)
                })?.id ?? machines.first?.id ?? machine
            }
        } catch {
            machines = []
            errors.append("Machine status failed: \(error)")
        }
        do {
            hostDevices = try await deviceScan
            if busid.isEmpty, let first = hostDevices.first {
                busid = first.busID
            }
        } catch {
            hostDevices = []
            errors.append("USB scan failed: \(error)")
        }
        status = errors.isEmpty ? "USB devices refreshed." : errors.joined(separator: "  ")
    }

    @MainActor private func attach() async {
        guard attachmentIsAvailable else {
            status = availabilityMessage
            return
        }
        busy = true
        defer { busy = false }
        do {
            let attachment = try await DorydClient().machineUSBAttach(
                cleanMachine(),
                busID: cleanBusID()
            )
            UserDefaults.standard.set(cleanMachine(), forKey: "dev.dory.usb.lastMachine")
            status = "Attached \(attachment.busID) on guest port \(attachment.port)."
        } catch {
            status = "Attach failed: \(error)"
        }
    }

    @MainActor private func detach() async {
        guard attachmentIsAvailable else {
            status = availabilityMessage
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await DorydClient().machineUSBDetach(cleanMachine(), busID: cleanBusID())
            try? UsbAttachmentStore().forget(machine: cleanMachine(), busID: cleanBusID())
            reloadRemembered()
            status = "Detached \(cleanBusID())."
        } catch {
            status = "Detach failed: \(error)"
        }
    }

    @MainActor private func forget(_ attachment: UsbAttachment) {
        try? UsbAttachmentStore().forget(machine: attachment.machine, busID: attachment.busID)
        reloadRemembered()
    }

    @MainActor private func reloadRemembered() {
        remembered = UsbAttachmentStore().attachments()
    }

    private func cleanMachine() -> String { machine.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func cleanBusID() -> String { busid.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var selectedMachine: DorydMachineStatus? {
        machines.first { $0.id == cleanMachine() }
    }

    private var attachmentIsAvailable: Bool {
        UsbPassthroughAvailability.attachSupported(for: selectedMachine)
    }

    private var availabilityMessage: String {
        UsbPassthroughAvailability.unavailableReason(for: selectedMachine)
    }

}
