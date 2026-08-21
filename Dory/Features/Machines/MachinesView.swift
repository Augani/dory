import AppKit
import Darwin
import DoryOperations
import SwiftUI

struct MachinesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    let displayMode: MachineDisplayMode

    private let columns = [GridItem(.adaptive(minimum: 340, maximum: 500), spacing: 14)]

    var body: some View {
        content
            .sheet(item: Binding(get: { store.editMachineTarget }, set: { store.editMachineTarget = $0 })) { machine in
                MachineEditSheet(machine: machine)
            }
    }

    @ViewBuilder private var content: some View {
        if matchingMachines.isEmpty && store.filter.isEmpty {
            emptyState
        } else if matchingFilteredMachines.isEmpty {
            TableEmptyState(
                glyph: .machines,
                title: "No matches",
                message: "No \(displayMode == .desktop ? "desktops" : "servers") match \u{201C}\(store.filter)\u{201D}."
            )
        } else {
            machineGrid
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Glyph(glyph: .machines, size: 44, color: p.accent)
                    .frame(width: 78, height: 78)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 20))
                VStack(spacing: 8) {
                    Text(displayMode == .desktop ? "No Linux desktops yet" : "No Linux servers yet")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(p.text)
                    Text(emptyMessage)
                        .font(.system(size: 13.5)).foregroundStyle(p.text2)
                        .multilineTextAlignment(.center).lineSpacing(4)
                        .frame(maxWidth: 460)
                }
                featurePills.padding(.top, 2)
                if displayMode != .desktop || AppInfo.includesDesktopLinux {
                    Button { store.activeSheet = displayMode == .desktop ? .newDesktop : .newMachine } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                            Text(displayMode == .desktop ? "Create a desktop" : "Create a server")
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(p.accent, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .accessibilityIdentifier(displayMode == .desktop ? "create-first-desktop" : "create-first-server")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 64).padding(.bottom, 32).padding(.horizontal, 24)
        }
    }

    private var featurePills: some View {
        HStack(spacing: 8) {
            featurePill("Isolated VM", "rectangle.stack.badge.person.crop")
            if displayMode == .desktop {
                featurePill("Graphical Linux", "display")
                featurePill("Desktop console", "macwindow")
            } else {
                featurePill("Headless Linux", "terminal")
                featurePill("Service ready", "bolt.horizontal")
            }
            featurePill("Persistent disk", "internaldrive")
        }
    }

    private var emptyMessage: String {
        displayMode == .desktop
            ? "Create a graphical Linux desktop with its own display, terminal, user, resources, folders, snapshots, and persistent disk."
            : "Create a lightweight Linux server for terminals, development tools, services, and VPS-style workflows."
    }

    private var matchingMachines: [Machine] {
        store.machines.filter { $0.displayMode == displayMode }
    }

    private var matchingFilteredMachines: [Machine] {
        let filteredIDs = Set(store.filteredMachines.map(\.id))
        return matchingMachines.filter { filteredIDs.contains($0.id) }
    }

    private func featurePill(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            Text(title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(p.text2)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(p.pill, in: Capsule())
    }

    private var machineGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(matchingFilteredMachines) { machine in
                    MachineCard(machine: machine)
                }
            }
            .padding(18)
        }
    }
}

private struct MachineCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.openWindow) private var openWindow
    let machine: Machine
    @State private var confirmingDelete = false
    @State private var confirmingToolsRepair = false
    @State private var showingIntegrationHealth = false
    @State private var isTransferDropTargeted = false

    private var isRunning: Bool { machine.status == .running }
    private var isPaused: Bool { machine.status == .paused }
    private var isActive: Bool { isRunning || isPaused }
    private var hasAssignedAddress: Bool { DoryDNS.ipv4Bytes(machine.ip) != nil }
    private var fileTransfer: DorydMachineFileTransferOperation? {
        store.machineFileTransfer(for: machine.name)
    }
    private var guestFileExport: DorydMachineGuestFileExportOperation? {
        store.machineGuestFileExport(for: machine.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                distroBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(p.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(machine.distro) \(machine.version)").font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(1)
                        if machine.isEmulated {
                            Text(machine.arch.uppercased())
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(p.amber).tracking(0.3)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(p.amberWeak, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                Spacer(minLength: 8)
                statusPill
                overflowMenu
            }

            HStack(alignment: .top, spacing: 0) {
                metric("CPU", isRunning ? String(format: "%.1f%%", machine.cpuPercent) : "—")
                metric("MEMORY", isActive ? machine.memoryDisplay : "—")
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasAssignedAddress ? "ADDRESS" : "DNS NAME").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text3).tracking(0.4)
                    Text(machine.ip).font(.mono(12.5, weight: .semibold)).foregroundStyle(isActive ? p.accentText : p.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 16).padding(.bottom, 14)

            if machine.username != "root", !machine.loginShell.isEmpty {
                Text("\(machine.username) · \(machine.loginShell)")
                    .font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(1)
                    .padding(.bottom, 12)
            }

            runtimeEvidence
                .padding(.bottom, 12)

            if let fileTransfer {
                fileTransferProgress(fileTransfer)
                    .padding(.bottom, 12)
            } else if let guestFileExport {
                guestFileExportProgress(guestFileExport)
                    .padding(.bottom, 12)
            }

            if let command = store.machineTerminalCommand(machine) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(p.text3)
                    Text(command).font(.mono(11)).foregroundStyle(p.text2).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(p.text3)
                    }.buttonStyle(.plain)
                }
                .padding(.bottom, 12)
            }

            if !machine.mounts.isEmpty {
                mountsSummary
                    .padding(.bottom, 12)
            }

            Divider().overlay(p.border)

            HStack(spacing: 8) {
                actionButton(
                    isRunning ? "stop.fill" : "play.fill",
                    isRunning ? "Stop" : (isPaused ? "Resume" : "Start"),
                    prominent: !isRunning
                ) {
                    store.toggleMachine(machine)
                }
                if isRunning {
                    actionButton("pause.fill", "Pause", prominent: false) {
                        store.pauseMachine(machine)
                    }
                }
                if machine.displayMode == .desktop {
                    actionButton("display", "Desktop", prominent: false, enabled: store.canOpenMachineDesktop(machine)) {
                        store.openMachineDesktop(machine)
                    }
                }
                actionButton("terminal", "Terminal", prominent: false, enabled: isRunning && store.canOpenMachineTerminal(machine)) {
                    openWindow(value: store.terminalSession(for: machine))
                }
                iconButton("trash") { confirmingDelete = true }
            }
            .padding(.top, 12)
        }
        .padding(16)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTransferDropTargeted ? p.accent : p.border,
                    lineWidth: isTransferDropTargeted ? 2 : 1
                )
        )
        .overlay {
            if isTransferDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(p.accentSoft.opacity(0.96))
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 24, weight: .semibold))
                        Text(store.canTransferFolders(to: machine)
                            ? "Send files or folders"
                            : "Send files")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Copies into a new Downloads folder")
                            .font(.system(size: 11))
                            .foregroundStyle(p.text2)
                    }
                    .foregroundStyle(p.accentText)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard store.canTransferFiles(to: machine),
                  !store.isMachineBusy(machine.name),
                  !urls.isEmpty,
                  urls.allSatisfy(\.isFileURL) else {
                return false
            }
            Task { await store.transferFiles(urls, to: machine) }
            return true
        } isTargeted: { targeted in
            isTransferDropTargeted = targeted
                && store.canTransferFiles(to: machine)
                && !store.isMachineBusy(machine.name)
        }
        .sheet(isPresented: $showingIntegrationHealth) {
            MachineIntegrationHealthSheet(machine: machine)
        }
        .confirmationDialog("Delete machine \(machine.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteMachine(machine) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the Linux machine and its disk. This cannot be undone.")
        }
        .confirmationDialog(
            "Repair Dory Tools in \(machine.name)?",
            isPresented: $confirmingToolsRepair,
            titleVisibility: .visible
        ) {
            Button("Repair Dory Tools") { store.repairMachineTools(machine) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dory will create a last-good snapshot, reinstall the active signed desktop and tools payload, restart the machine, and roll back automatically if verification fails.")
        }
    }

    private var distroBadge: some View {
        Group {
            if let logo = logoName(for: machine.distro) {
                Image(logo).resizable().aspectRatio(contentMode: .fit).frame(width: 30, height: 30)
            } else {
                Text(machine.letter)
                    .font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(machine.badgeColor, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .frame(width: 44, height: 44)
        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.border))
    }

    private func fileTransferProgress(_ operation: DorydMachineFileTransferOperation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: operation.phase == .cancelling ? "xmark.circle" : "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.accentText)
                Text(fileTransferTitle(operation))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(operation.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .font(.mono(10.5, weight: .semibold))
                    .foregroundStyle(p.text2)
            }

            ProgressView(value: operation.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(p.accent)

            HStack(spacing: 8) {
                Text(fileTransferDetail(operation))
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if !operation.phase.isTerminal {
                    Button(operation.phase == .cancelling ? "Cancelling…" : "Cancel") {
                        Task { await store.cancelFileTransfer(to: machine) }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .semibold))
                    .disabled(operation.phase == .cancelling)
                    .accessibilityIdentifier("machine-transfer-cancel-\(machine.name)")
                }
            }
        }
        .padding(10)
        .background(p.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.accent.opacity(0.24)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File transfer to \(machine.name)")
        .accessibilityValue(fileTransferDetail(operation))
    }

    private func fileTransferTitle(_ operation: DorydMachineFileTransferOperation) -> String {
        switch operation.phase {
        case .preparing: "Preparing files"
        case .transferring: "Sending files"
        case .finalizing: "Finishing transfer"
        case .cancelling: "Cancelling transfer"
        case .completed: "Files sent"
        case .cancelled: "Transfer cancelled"
        case .failed: "Transfer failed"
        }
    }

    private func fileTransferDetail(_ operation: DorydMachineFileTransferOperation) -> String {
        if let currentPath = operation.currentPath {
            return currentPath
        }
        if operation.bytesTotal > 0 {
            let completed = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: operation.bytesCompleted),
                countStyle: .file
            )
            let total = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: operation.bytesTotal),
                countStyle: .file
            )
            return "\(completed) of \(total)"
        }
        if operation.filesTotal > 0 {
            return "\(operation.filesCompleted) of \(operation.filesTotal) files"
        }
        return fileTransferTitle(operation)
    }

    private func guestFileExportProgress(
        _ operation: DorydMachineGuestFileExportOperation
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: operation.phase == .cancelling
                    ? "xmark.circle" : "square.and.arrow.down.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(p.accentText)
                Text(guestFileExportTitle(operation))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(operation.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .font(.mono(10.5, weight: .semibold))
                    .foregroundStyle(p.text2)
            }

            ProgressView(value: operation.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(p.accent)

            HStack(spacing: 8) {
                Text(guestFileExportDetail(operation))
                    .font(.system(size: 10.5))
                    .foregroundStyle(p.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if operation.phase == .completed {
                    Button("Save…") { savePendingGuestFileExport() }
                        .accessibilityIdentifier("machine-export-save-\(machine.name)")
                    Button("Discard") {
                        Task { await store.discardGuestFileExport(from: machine) }
                    }
                    .accessibilityIdentifier("machine-export-discard-\(machine.name)")
                } else if !operation.phase.isTerminal {
                    Button(operation.phase == .cancelling ? "Cancelling…" : "Cancel") {
                        Task { await store.cancelGuestFileExport(from: machine) }
                    }
                    .disabled(operation.phase == .cancelling)
                    .accessibilityIdentifier("machine-export-cancel-\(machine.name)")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5, weight: .semibold))
        }
        .padding(10)
        .background(p.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.accent.opacity(0.24)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File export from \(machine.name)")
        .accessibilityValue(guestFileExportDetail(operation))
    }

    private func guestFileExportTitle(
        _ operation: DorydMachineGuestFileExportOperation
    ) -> String {
        switch operation.phase {
        case .preparing: "Preparing export"
        case .transferring: "Receiving files"
        case .finalizing: "Verifying files"
        case .cancelling: "Cancelling export"
        case .completed: "Files ready to save"
        case .cancelled: "Export cancelled"
        case .failed: "Export failed"
        }
    }

    private func guestFileExportDetail(
        _ operation: DorydMachineGuestFileExportOperation
    ) -> String {
        if operation.phase == .completed, let result = operation.result {
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: result.bytesReceived),
                countStyle: .file
            )
            let fileLabel = result.filesReceived == 1 ? "file" : "files"
            return "\(result.filesReceived) \(fileLabel) · \(bytes)"
        }
        if let currentPath = operation.currentPath {
            return currentPath
        }
        if operation.bytesTotal > 0 {
            let completed = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: operation.bytesCompleted),
                countStyle: .file
            )
            let total = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: operation.bytesTotal),
                countStyle: .file
            )
            return "\(completed) of \(total)"
        }
        return guestFileExportTitle(operation)
    }

    private var overflowMenu: some View {
        Menu {
            if isActive {
                Button { store.restartMachine(machine) } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                if isRunning {
                    Button { selectAndSendFiles() } label: {
                        Label(
                            store.canTransferFolders(to: machine)
                                ? "Send Files or Folders\u{2026}" : "Send Files\u{2026}",
                            systemImage: "paperplane"
                        )
                    }
                    .disabled(!store.canTransferFiles(to: machine))
                    .help(
                        store.canTransferFolders(to: machine)
                            ? "Copy selected files and folders into this machine's Downloads folder"
                            : "Copy selected files into this machine's Downloads folder"
                    )
                    Button { selectAndReceiveFiles() } label: {
                        Label("Receive Files or Folder…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!store.canExportGuestFiles(from: machine))
                    .help("Copy a file or folder from this machine into a folder on your Mac")
                }
                Divider()
            }
            Button { store.takeSnapshot(machine, note: "") } label: {
                Label("Snapshot", systemImage: "camera.aperture")
            }
            Button { store.openSnapshots(machine) } label: {
                Label("Snapshots…", systemImage: "clock.arrow.circlepath")
            }
            Divider()
            Button { store.cloneMachine(machine) } label: {
                Label("Clone…", systemImage: "doc.on.doc")
            }
            Button { store.exportMachine(machine) } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            Button { store.openMachineEdit(machine) } label: {
                Label("Edit…", systemImage: "slider.horizontal.3")
            }
            Button { showingIntegrationHealth = true } label: {
                Label("Integration Health…", systemImage: "stethoscope")
            }
            if store.canRepairMachineTools(machine) {
                Button { confirmingToolsRepair = true } label: {
                    Label("Repair Dory Tools…", systemImage: "wrench.and.screwdriver")
                }
            }
            if machine.bootMode == .efi {
                Divider()
                Button {
                    store.setMachineInstallerMedia(machine, attached: !machine.installerMediaAttached)
                } label: {
                    Label(
                        machine.installerMediaAttached ? "Eject Installer ISO" : "Attach Installer ISO",
                        systemImage: machine.installerMediaAttached ? "eject" : "opticaldiscdrive"
                    )
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(p.text2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .fixedSize()
        .disabled(store.isMachineBusy(machine.name) || !store.canUseMachineArtifacts(machine))
    }

    private func selectAndSendFiles() {
        guard store.canTransferFiles(to: machine) else { return }
        let supportsFolders = store.canTransferFolders(to: machine)
        let panel = NSOpenPanel()
        panel.title = supportsFolders
            ? "Send files or folders to \(machine.name)"
            : "Send files to \(machine.name)"
        panel.message = supportsFolders
            ? "Files and folders are copied into a new folder in the machine's Downloads folder."
            : "Files are copied into a new folder in the machine's Downloads folder. Update Dory Tools to send folders."
        panel.prompt = "Send"
        panel.canChooseFiles = true
        panel.canChooseDirectories = supportsFolders
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        guard panel.runModal() == .OK else { return }
        let selected = panel.urls
        guard !selected.isEmpty else { return }
        Task { await store.transferFiles(selected, to: machine) }
    }

    private func selectAndReceiveFiles() {
        guard store.canExportGuestFiles(from: machine),
              let guestSource = promptForGuestSource() else {
            return
        }
        let name = guestExportName(for: guestSource)
        guard let destination = selectGuestExportDestination(suggestedName: name) else {
            return
        }
        Task {
            await store.exportGuestFiles(
                guestSource,
                from: machine,
                to: destination
            )
        }
    }

    private func savePendingGuestFileExport() {
        let name = store.suggestedGuestFileExportName(for: machine.name)
        guard let destination = selectGuestExportDestination(suggestedName: name) else {
            return
        }
        Task { await store.saveGuestFileExport(from: machine, to: destination) }
    }

    private func promptForGuestSource() -> String? {
        let home = "/home/\(machine.username)"
        let alert = NSAlert()
        alert.messageText = "Receive files from \(machine.name)"
        alert.informativeText = "Enter a file or folder inside \(home). Dory verifies the guest transfer before saving it on your Mac."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: home + "/Documents")
        field.placeholderString = home + "/Documents/project"
        field.frame = NSRect(x: 0, y: 0, width: 390, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func selectGuestExportDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save files from \(machine.name)"
        panel.message = "Dory creates a new folder at this location and never overwrites an existing item."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func guestExportName(for guestSource: String) -> String {
        let name = URL(fileURLWithPath: guestSource).lastPathComponent
        guard !name.isEmpty,
              name != ".dory-sync-tmp",
              name.utf8.count <= 255 else {
            return "\(machine.name)-export"
        }
        return name
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle().fill(machine.status.dotColor(p)).frame(width: 6, height: 6)
            Text(machine.status.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(machine.status.dotColor(p))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(machine.status.badgeBackground(p), in: Capsule())
        .fixedSize()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text3).tracking(0.4)
            Text(value).font(.system(size: 14.5, weight: .bold)).monospacedDigit().foregroundStyle(p.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mountsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(p.text3)
                Text("MOUNTED FOLDERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.text3).tracking(0.4)
            }
            ForEach(Array(machine.mounts.prefix(2)).indices, id: \.self) { index in
                let mount = machine.mounts[index]
                HStack(spacing: 6) {
                    Text(mount.host).font(.mono(10.5)).foregroundStyle(p.text2).lineLimit(1).truncationMode(.head)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(p.text3)
                    Text(mount.guest).font(.mono(10.5, weight: .semibold)).foregroundStyle(p.text).lineLimit(1).truncationMode(.middle)
                    if mount.readOnly {
                        Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(p.text3)
                    }
                }
            }
            if machine.mounts.count > 2 {
                Text("+ \(machine.mounts.count - 2) more")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(p.text3)
            }
        }
    }

    private var runtimeEvidence: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104, maximum: 190), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(machine.runtimeEvidence) { evidence in
                HStack(spacing: 4) {
                    Image(systemName: evidence.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                    Text(evidence.label)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(runtimeEvidenceColor(evidence.tone))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(runtimeEvidenceBackground(evidence.tone), in: Capsule())
                .help(evidence.detail)
            }
        }
    }

    private func runtimeEvidenceColor(_ tone: MachineRuntimeEvidenceTone) -> Color {
        switch tone {
        case .standard: p.text2
        case .positive: p.green
        case .warning: p.amber
        }
    }

    private func runtimeEvidenceBackground(_ tone: MachineRuntimeEvidenceTone) -> Color {
        switch tone {
        case .standard: p.pill
        case .positive: p.greenWeak
        case .warning: p.amberWeak
        }
    }

    private func actionButton(_ systemImage: String, _ title: String, prominent: Bool, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? p.accentText : p.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(prominent ? p.accentSoft : p.bgInput, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? p.accentWeak : p.border))
        }
        .buttonStyle(.plain)
        .disabled(store.isMachineBusy(machine.name) || !enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func iconButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(p.red)
                .frame(width: 34, height: 30)
                .background(p.redWeak, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .disabled(store.isMachineBusy(machine.name))
        .help("Delete machine")
    }
}

private func logoName(for distro: String) -> String? {
    let lower = distro.lowercased()
    for family in ["ubuntu", "debian", "fedora", "alpine", "rocky", "alma", "opensuse", "oracle", "amazon", "kali", "centos", "arch"] {
        if lower.contains(family) { return "logo-\(family)" }
    }
    return nil
}

private struct MachineIntegrationHealthSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p
    let machine: Machine
    @State private var confirmingRepair = false

    private var health: DoryGuestIntegrationHealth { machine.integrationHealthProjection }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: healthIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(healthColor)
                    .frame(width: 42, height: 42)
                    .background(healthBackground, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Integration Health")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(p.text)
                    Text(machine.name)
                        .font(.mono(12, weight: .semibold))
                        .foregroundStyle(p.text3)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider().overlay(p.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    healthSummary

                    VStack(alignment: .leading, spacing: 9) {
                        Text("INTEGRATIONS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(p.text3)
                            .tracking(0.7)
                        ForEach(health.features, id: \.id) { feature in
                            featureRow(feature)
                        }
                    }
                }
                .padding(20)
            }

            if store.canRepairMachineTools(machine) {
                Divider().overlay(p.border)
                HStack {
                    Text("Repair reinstalls the active signed Dory Tools payload with rollback.")
                        .font(.system(size: 11))
                        .foregroundStyle(p.text3)
                    Spacer()
                    Button("Repair Dory Tools…") { confirmingRepair = true }
                        .disabled(store.isMachineBusy(machine.name))
                }
                .padding(16)
            }
        }
        .frame(width: 610, height: 650)
        .background(p.bgContent)
        .confirmationDialog(
            "Repair Dory Tools in \(machine.name)?",
            isPresented: $confirmingRepair,
            titleVisibility: .visible
        ) {
            Button("Repair Dory Tools") {
                store.repairMachineTools(machine)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dory will create a last-good snapshot, reinstall the active signed desktop and tools payload, restart the machine, and roll back automatically if verification fails.")
        }
    }

    private var healthSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(healthTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(healthColor)
                Text(health.runtimeAuthority.rawValue)
                    .font(.mono(10, weight: .semibold))
                    .foregroundStyle(p.text2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(p.pill, in: Capsule())
            }
            Text(healthDescription)
                .font(.system(size: 12))
                .foregroundStyle(p.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                summaryValue("TOOLS BUILD", health.agentBuild ?? "Not connected")
                summaryValue(
                    "PROTOCOL",
                    health.agentProtocolVersion.map(String.init) ?? "—"
                )
                summaryValue(
                    "ACTIVE",
                    "\(health.features.filter { $0.state == .active }.count)/\(health.features.count)"
                )
            }
        }
        .padding(14)
        .background(healthBackground.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(p.border))
    }

    private func summaryValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(p.text3)
                .tracking(0.5)
            Text(value)
                .font(.mono(11, weight: .semibold))
                .foregroundStyle(p.text)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(_ feature: DoryGuestIntegrationFeatureHealth) -> some View {
        HStack(spacing: 10) {
            Image(systemName: featureIcon(feature.state))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(featureColor(feature.state))
                .frame(width: 24, height: 24)
                .background(featureBackground(feature.state), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(featureTitle(feature.id))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.text)
                    if feature.required {
                        Text("REQUIRED")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(p.text3)
                    }
                }
                Text("\(feature.provider.rawValue) · \(featureVersion(feature))")
                    .font(.mono(9.5))
                    .foregroundStyle(p.text3)
            }
            Spacer()
            Text(featureStateTitle(feature.state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(featureColor(feature.state))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.border))
    }

    private var healthTitle: String {
        switch health.state {
        case .inactive: "Inactive"
        case .missingTools: "Dory Tools missing"
        case .incompatible: "Dory Tools incompatible"
        case .degraded: "Integration degraded"
        case .compatibility: "Compatibility mode"
        case .healthy: "All required integrations healthy"
        }
    }

    private var healthDescription: String {
        switch health.state {
        case .inactive: "The workspace is stopped. Live guest-integration evidence is intentionally inactive."
        case .missingTools: "The running guest has not completed a valid Dory Tools handshake."
        case .incompatible: "The running guest reported a tools protocol this version of Dory cannot use."
        case .degraded: "One or more required capabilities are unavailable, outdated, or need a current runtime plan."
        case .compatibility: "Guest capabilities are negotiated, but host runtime integrations are not backed by a qualified resolved plan."
        case .healthy: "The daemon verified the runtime authority and every required integration is active."
        }
    }

    private var healthIcon: String {
        switch health.state {
        case .healthy: "checkmark.seal.fill"
        case .inactive: "pause.circle.fill"
        case .compatibility: "arrow.triangle.2.circlepath"
        default: "exclamationmark.triangle.fill"
        }
    }

    private var healthColor: Color {
        switch health.state {
        case .healthy: p.green
        case .inactive, .compatibility: p.text2
        default: p.amber
        }
    }

    private var healthBackground: Color {
        switch health.state {
        case .healthy: p.greenWeak
        case .inactive, .compatibility: p.pill
        default: p.amberWeak
        }
    }

    private func featureTitle(_ id: DoryGuestIntegrationCapabilityID) -> String {
        switch id {
        case .readiness: "Guest readiness"
        case .gracefulShutdown: "Graceful shutdown"
        case .reboot: "Guest reboot"
        case .clockSynchronization: "Clock synchronization"
        case .health: "Health reporting"
        case .displayTopology: "Display topology"
        case .displayResize: "Dynamic display resize"
        case .clipboardText: "Text clipboard"
        case .clipboardImage: "Image clipboard"
        case .sharedFolderDiscovery: "Shared-folder discovery"
        case .sharedFolderMountStatus: "Shared-folder mount status"
        case .fileTransferPush: "Host-to-guest transfer"
        case .fileTransferPull: "Guest-to-host transfer"
        case .networkIdentity: "Network identity"
        case .processLaunch: "Process launch"
        case .processInput: "Process input"
        case .listenPorts: "Port discovery"
        case .telemetry: "Telemetry"
        case .snapshotQuiesce: "Snapshot freeze/thaw"
        case .packageUpdate: "Tools update"
        }
    }

    private func featureVersion(_ feature: DoryGuestIntegrationFeatureHealth) -> String {
        guard let minimum = feature.minimumVersion else { return "runtime-qualified" }
        if let negotiated = feature.negotiatedVersion {
            return "v\(negotiated), requires v\(minimum)+"
        }
        return "requires v\(minimum)+"
    }

    private func featureStateTitle(_ state: DoryGuestIntegrationFeatureState) -> String {
        switch state {
        case .inactive: "Inactive"
        case .active: "Active"
        case .unavailable: "Unavailable"
        case .updateRequired: "Update required"
        case .unqualified: "Unqualified"
        }
    }

    private func featureIcon(_ state: DoryGuestIntegrationFeatureState) -> String {
        switch state {
        case .active: "checkmark"
        case .inactive: "pause.fill"
        case .updateRequired: "arrow.clockwise"
        case .unavailable, .unqualified: "exclamationmark"
        }
    }

    private func featureColor(_ state: DoryGuestIntegrationFeatureState) -> Color {
        switch state {
        case .active: p.green
        case .inactive, .unqualified: p.text3
        case .unavailable, .updateRequired: p.amber
        }
    }

    private func featureBackground(_ state: DoryGuestIntegrationFeatureState) -> Color {
        switch state {
        case .active: p.greenWeak
        case .inactive, .unqualified: p.pill
        case .unavailable, .updateRequired: p.amberWeak
        }
    }
}

private struct MachineEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let machine: Machine

    @State private var cpus = 4
    @State private var memoryGB = 4
    @State private var address = ""
    @State private var displayMode: MachineDisplayMode = .headless
    @State private var guestUsername = "dory"
    @State private var clipboardPolicy = DoryDesktopClipboardPolicy.bidirectional
    @State private var runtimePreference = DoryDesktopVMMPreference.automatic
    @State private var graphicsPreference = DoryDesktopGraphicsPreference.automatic
    @State private var networkMode = DoryVMNetworkMode.sharedNAT
    @State private var typedSettings = DorydMachineTypedSettings()

    private struct MountRow: Identifiable, Hashable {
        let id = UUID()
        var host = ""
        var guest = ""
        var readOnly = false
        var shareTag: String? = nil
    }

    @State private var mountRows: [MountRow] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    warning
                    machineTypeBlock
                    networkBlock
                    runtimeBlock
                    clipboardBlock
                    resourceRow
                    addressBlock
                    mountsBlock
                }
                .padding(20)
            }
            Divider().overlay(p.border)
            footer
        }
        .frame(width: 560, height: 560)
        .background(p.bgWindow)
        .task { await load() }
    }

    private func load() async {
        let settings = await store.machineSettings(machine.name)
        cpus = max(1, min(8, settings.cpus ?? 4))
        memoryGB = max(1, min(16, settings.memoryMB.map { $0 / 1024 } ?? 4))
        address = settings.address ?? ""
        displayMode = settings.displayMode
        typedSettings = settings.virtualMachineSettings ?? DorydMachineTypedSettings(
            legacyEnvironment: settings.env,
            displayMode: settings.displayMode
        )
        // Keep an unrepresentable legacy username visible and invalid until the user explicitly
        // corrects that field. Hiding it behind a default would turn an unrelated edit into a
        // destructive rewrite.
        guestUsername = settings.env[DoryVMGuestAccountIntent.legacyUsernameEnvironmentKey]
            ?? typedSettings.guestIdentityIntent.account?.username
            ?? "dory"
        clipboardPolicy = typedSettings.clipboardPolicy.flatMap {
            guard $0.text == $0.image, $0.files == .off else { return nil }
            return DoryDesktopClipboardPolicy(rawValue: $0.text.rawValue)
        } ?? .bidirectional
        runtimePreference = typedSettings.runtimePreference ?? .automatic
        graphicsPreference = typedSettings.graphicsPreference ?? .automatic
        networkMode = typedSettings.networkMode ?? .sharedNAT
        mountRows = settings.mounts.map {
            MountRow(host: $0.host, guest: $0.guest, readOnly: $0.readOnly, shareTag: $0.shareTag)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Glyph(glyph: .machines, size: 18, color: p.accent)
                .frame(width: 36, height: 36)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text("Edit \(machine.name)").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
                Text(machine.bootMode == .efi
                     ? "Apply resources, address and mounted folders"
                     : "Apply user, resources, address and mounted folders")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var warning: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle.fill").font(.system(size: 13)).foregroundStyle(p.accent)
            Text(machine.bootMode == .efi
                 ? "Resource and mount changes restart a running machine automatically. The EFI machine type is fixed to protect its installed disk."
                 : "Resource, user and mount changes restart a running machine automatically. The machine type is fixed to protect its existing disk.")
                .font(.system(size: 12)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 9))
    }

    private var machineTypeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("MACHINE TYPE")
            HStack(spacing: 10) {
                Image(systemName: displayMode == .desktop ? "display" : "terminal.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accent)
                    .frame(width: 34, height: 34)
                    .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.bootMode == .efi ? "Custom EFI Linux" : (displayMode == .desktop ? "Desktop Linux" : "Headless Linux"))
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                    Text(displayMode == .desktop ? "\(machine.distro) \(machine.version)" : "Lightweight Dory Linux")
                        .font(.system(size: 11)).foregroundStyle(p.text3)
                }
                Spacer(minLength: 0)
                if displayMode == .desktop, machine.bootMode != .efi {
                    TextField("dory", text: $guestUsername)
                        .textFieldStyle(.plain)
                        .font(.mono(11.5)).foregroundStyle(p.text)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(width: 160)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(guestUsernameInvalid ? p.red : p.border))
                        .accessibilityIdentifier("edit-machine-guest-user")
                }
            }
            .padding(11)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
            if guestUsernameInvalid {
                Text("Use 1–32 lowercase letters, numbers, underscores or dashes; start with a letter or underscore.")
                    .font(.system(size: 11)).foregroundStyle(p.red)
            }
        }
    }

    private var resourceRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("CPUS")
                Stepper(value: $cpus, in: 1...8) {
                    Text("\(cpus) \(cpus == 1 ? "core" : "cores")")
                        .font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("edit-machine-cpus")
                .frame(width: 180)
            }
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("MEMORY")
                Stepper(value: $memoryGB, in: 1...16) {
                    Text("\(memoryGB) GB").font(.system(size: 12.5)).foregroundStyle(p.text)
                }
                .accessibilityIdentifier("edit-machine-memory")
                .frame(width: 180)
            }
            Spacer(minLength: 0)
        }
    }

    private var networkBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NETWORK")
            Picker("Network", selection: $networkMode) {
                Text("Shared NAT").tag(DoryVMNetworkMode.sharedNAT)
                Text("Disconnected").tag(DoryVMNetworkMode.disconnected)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("edit-machine-network-mode")
            Text(networkMode == .disconnected
                 ? "Disconnected keeps the virtual adapter present with its link down."
                 : "Shared NAT provides outbound access through your Mac without exposing the machine directly.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
        }
    }

    @ViewBuilder private var clipboardBlock: some View {
        if displayMode == .desktop, machine.bootMode != .efi {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("CLIPBOARD SHARING")
                Picker("Clipboard sharing", selection: $clipboardPolicy) {
                    ForEach(DoryDesktopClipboardPolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("edit-machine-clipboard-policy")
                Text("Control whether text and images can move between this Linux desktop and your Mac.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    @ViewBuilder private var runtimeBlock: some View {
        if displayMode == .desktop, machine.bootMode != .efi {
            VStack(alignment: .leading, spacing: 9) {
                sectionLabel("DISPLAY ENGINE")
                HStack(spacing: 14) {
                    Picker("Virtual machine", selection: $runtimePreference) {
                        Text("Automatic").tag(DoryDesktopVMMPreference.automatic)
                        Text("Accelerated").tag(DoryDesktopVMMPreference.accelerated)
                        Text("Compatibility").tag(DoryDesktopVMMPreference.compatible)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("edit-machine-vmm-preference")

                    Picker("Graphics", selection: $graphicsPreference) {
                        Text("Automatic").tag(DoryDesktopGraphicsPreference.automatic)
                        Text("VirGL").tag(DoryDesktopGraphicsPreference.virgl)
                        Text("VirGL + Venus").tag(DoryDesktopGraphicsPreference.virglVenus)
                        Text("Software").tag(DoryDesktopGraphicsPreference.software)
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(runtimePreference == .compatible)
                    .accessibilityIdentifier("edit-machine-graphics-preference")
                }
                Text(runtimePreference == .compatible
                     ? "Compatibility uses Apple's Virtualization framework; the raw graphics choice is kept for when you switch back."
                     : "Automatic uses VirGL for the desktop and Venus for Vulkan apps, then falls back safely when acceleration is unavailable.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DNS TARGET OVERRIDE")
            fieldInput("192.168.215.42", text: $address, width: 260)
            Text("Advanced: override the address reported by the guest for \(machine.name).dory.local. Leave blank to clear.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
        }
    }

    private var mountsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("MOUNTED FOLDERS")
                Spacer(minLength: 0)
                addButton { mountRows.append(MountRow()) }
            }
            ForEach($mountRows) { $row in
                HStack(spacing: 8) {
                    Button { chooseMountHost(for: row.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(p.text3)
                            Text(row.host.isEmpty ? "Host folder…" : row.host)
                                .font(.mono(11.5)).foregroundStyle(row.host.isEmpty ? p.text3 : p.text)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                    }
                    .buttonStyle(.plain)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(p.text3)
                    fieldInput("/guest/path", text: $row.guest, width: 150)
                    modeButton(readOnly: $row.readOnly)
                    removeButton { mountRows.removeAll { $0.id == row.id } }
                }
            }
            if mountRows.isEmpty {
                Text("Share host folders into the machine.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 8)
            Button("Cancel") { store.editMachineTarget = nil }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(p.text2)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
            Button(action: apply) {
                HStack(spacing: 6) {
                    if store.isMachineBusy(machine.name) { ProgressView().controlSize(.small) }
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    Text("Apply").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(p.accent.opacity(store.isMachineBusy(machine.name) ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(store.isMachineBusy(machine.name) || guestUsernameInvalid)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3).tracking(0.5)
    }

    private func fieldInput(_ placeholder: String, text: Binding<String>, width: CGFloat) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.mono(11.5)).foregroundStyle(p.text)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: width)
            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
    }

    private func addButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(p.accent)
                .frame(width: 22, height: 22)
                .background(p.accentSoft, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").font(.system(size: 14)).foregroundStyle(p.text3)
        }
        .buttonStyle(.plain)
    }

    private func modeButton(readOnly: Binding<Bool>) -> some View {
        Button {
            readOnly.wrappedValue.toggle()
        } label: {
            Image(systemName: readOnly.wrappedValue ? "lock" : "lock.open")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(readOnly.wrappedValue ? p.amber : p.text3)
                .frame(width: 26, height: 26)
                .background(p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .help(readOnly.wrappedValue ? "Read-only" : "Read-write")
    }

    private func chooseMountHost(for id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a host folder to mount into the machine"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = mountRows.firstIndex(where: { $0.id == id }) else { return }
        mountRows[index].host = url.path
        if mountRows[index].guest.isEmpty {
            mountRows[index].guest = "/mnt/\(url.lastPathComponent)"
        }
    }

    private func apply() {
        var mounts = mountRows.compactMap { row -> MountPair? in
            let host = row.host.trimmingCharacters(in: .whitespaces)
            let guest = row.guest.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !guest.isEmpty else { return nil }
            return MountPair(
                host: host,
                guest: guest,
                readOnly: row.readOnly,
                shareTag: row.shareTag
            )
        }
        typedSettings.networkMode = networkMode
        if displayMode == .desktop, machine.bootMode != .efi {
            let previousUsername = typedSettings.guestIdentityIntent.account?.username ?? "dory"
            if previousUsername != normalizedGuestUsername {
                let previousHome = "/home/\(previousUsername)"
                let updatedHome = "/home/\(normalizedGuestUsername)"
                mounts = mounts.map { mount in
                    guard mount.guest == previousHome || mount.guest.hasPrefix(previousHome + "/") else {
                        return mount
                    }
                    return MountPair(
                        host: mount.host,
                        guest: updatedHome + String(mount.guest.dropFirst(previousHome.count)),
                        readOnly: mount.readOnly,
                        shareTag: mount.shareTag
                    )
                }
            }
            typedSettings.guestIdentityIntent.account = DoryVMGuestAccountIntent(
                username: normalizedGuestUsername,
                numericUserID: typedSettings.guestIdentityIntent.account?.numericUserID
            )
            if typedSettings.clipboardPolicy != nil || clipboardPolicy != .bidirectional {
                typedSettings.clipboardPolicy = .legacyDesktop(
                    DoryVMClipboardDirection(rawValue: clipboardPolicy.rawValue)
                        ?? .bidirectional
                )
            }
            if typedSettings.runtimePreference != nil || runtimePreference != .automatic {
                typedSettings.runtimePreference = runtimePreference
            }
            if typedSettings.graphicsPreference != nil || graphicsPreference != .automatic {
                typedSettings.graphicsPreference = graphicsPreference
            }
        }
        let settings = MachineSettings(
            cpus: cpus,
            memoryMB: memoryGB * 1024,
            mounts: mounts,
            env: [:],
            virtualMachineSettings: typedSettings,
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            displayMode: displayMode,
            bootMode: machine.bootMode
        )
        let target = machine
        store.editMachineTarget = nil
        Task { _ = await store.editMachine(target, settings: settings) }
    }

    private var normalizedGuestUsername: String {
        guestUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var guestUsernameInvalid: Bool {
        guard displayMode == .desktop, machine.bootMode != .efi else { return false }
        return normalizedGuestUsername.range(
            of: "^[a-z_][a-z0-9_-]{0,31}$",
            options: .regularExpression
        ) == nil
    }
}
