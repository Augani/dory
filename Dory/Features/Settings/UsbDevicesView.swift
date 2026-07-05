import SwiftUI

struct UsbDevicesView: View {
    @Environment(\.palette) private var p
    @State private var devicesOutput = ""
    @State private var machine = UserDefaults.standard.string(forKey: "dev.dory.usb.lastMachine") ?? "default"
    @State private var busid = ""
    @State private var port = ""
    @State private var rememberAttachment = true
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
                    Text(devicesOutput.isEmpty ? "No USB scan has run yet." : devicesOutput)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(devicesOutput.isEmpty ? p.text3 : p.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
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
                HStack(spacing: 10) {
                    TextField("machine", text: $machine)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityIdentifier("usb-machine")
                    TextField("bus id or vid:pid", text: $busid)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityIdentifier("usb-busid")
                    TextField("port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 76)
                        .accessibilityIdentifier("usb-port")
                }

                Toggle("Remember for this machine", isOn: $rememberAttachment)
                    .font(.system(size: 12.5))
                    .toggleStyle(.checkbox)

                if rememberAttachment && validRememberPort() == nil {
                    Text("Enter a valid port (1-65535) to remember this attachment for automatic replay.")
                        .font(.system(size: 11))
                        .foregroundStyle(p.text3)
                }

                HStack(spacing: 10) {
                    Button { Task { await attach() } } label: {
                        Label("Attach", systemImage: "cable.connector")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || busid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button { Task { await detach() } } label: {
                        Label("Detach", systemImage: "xmark.circle")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(busy || busid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            if devicesOutput.isEmpty { await refresh() }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
            .padding(.bottom, -10)
    }

    @MainActor private func refresh() async {
        busy = true
        defer { busy = false }
        let result = await Self.runDory(["usb", "ls"])
        devicesOutput = result.output
        status = result.succeeded ? "USB devices refreshed." : "USB scan failed: \(result.output)"
    }

    @MainActor private func attach() async {
        busy = true
        defer { busy = false }
        let args = usbCommand("attach")
        let result = await Self.runDory(args)
        if result.succeeded {
            rememberIfNeeded()
            status = "Attached \(cleanBusID())."
        } else {
            status = "Attach failed: \(result.output)"
        }
    }

    @MainActor private func detach() async {
        busy = true
        defer { busy = false }
        let args = usbCommand("detach")
        let result = await Self.runDory(args)
        if result.succeeded {
            try? UsbAttachmentStore().forget(machine: cleanMachine(), busID: cleanBusID())
            reloadRemembered()
            status = "Detached \(cleanBusID())."
        } else {
            status = "Detach failed: \(result.output)"
        }
    }

    @MainActor private func rememberIfNeeded() {
        guard rememberAttachment else { return }
        guard let port = validRememberPort() else {
            status = "Attached \(cleanBusID()), but not remembered: enter a valid port (1-65535) to replay it automatically."
            return
        }
        do {
            UserDefaults.standard.set(cleanMachine(), forKey: "dev.dory.usb.lastMachine")
            _ = try UsbAttachmentStore().remember(machine: cleanMachine(), busID: cleanBusID(), port: port)
            reloadRemembered()
        } catch {
            status = "Attached, but could not remember it: \(error)"
        }
    }

    private func validRememberPort() -> Int? {
        guard let port = Int(cleanPort()), (1...65_535).contains(port) else { return nil }
        return port
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
    private func cleanPort() -> String { port.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func usbCommand(_ action: String) -> [String] {
        var args = ["usb", action, cleanBusID()]
        if !cleanPort().isEmpty {
            args += ["--port", cleanPort()]
        }
        if !cleanMachine().isEmpty {
            args += ["--machine", cleanMachine()]
        }
        return args
    }

    nonisolated static func runDory(_ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = doryCLIURL()
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return CommandResult(succeeded: process.terminationStatus == 0, output: output)
            } catch {
                return CommandResult(succeeded: false, output: error.localizedDescription)
            }
        }.value
    }

    nonisolated private static func doryCLIURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["DORY_CLI"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/dory") {
            return URL(fileURLWithPath: "/usr/local/bin/dory")
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/dory")
    }

    struct CommandResult: Sendable, Equatable {
        let succeeded: Bool
        let output: String
    }
}
