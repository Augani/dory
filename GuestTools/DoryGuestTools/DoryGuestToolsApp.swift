import AppKit
import DoryMacGuestCamera
import SwiftUI
import SystemExtensions

private let cameraExtensionIdentifier = "com.pythonxi.Dory.GuestTools.CameraExtension"

@MainActor
final class CameraPreviewController: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var status = "Test the direct Dory camera feed before installing the system camera."
    @Published private(set) var isRunning = false

    private var client: DoryMacGuestCameraClient?
    private var streamTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        let client = DoryMacGuestCameraClient()
        self.client = client
        image = nil
        status = "Connecting to the Mac host camera…"
        isRunning = true
        streamTask = Task.detached(priority: .userInitiated) { [weak self, client] in
            do {
                try client.connect()
                await self?.didConnect(client)
                while !Task.isCancelled {
                    let frame = try client.nextFrame()
                    await self?.publish(frame.jpeg, from: client)
                }
            } catch {
                await self?.didStop(client, error: error)
            }
        }
    }

    func stop() {
        guard let client else { return }
        streamTask?.cancel()
        client.stop()
        streamTask = nil
        self.client = nil
        isRunning = false
        status = image == nil ? "Camera test stopped." : "Direct camera feed verified."
    }

    private func didConnect(_ client: DoryMacGuestCameraClient) {
        guard self.client === client else { return }
        status = "Receiving the Mac host camera through Dory…"
    }

    private func publish(_ jpeg: Data, from client: DoryMacGuestCameraClient) {
        guard self.client === client else { return }
        guard let decoded = NSImage(data: jpeg) else {
            status = "Dory received a camera frame that macOS could not decode."
            return
        }
        image = decoded
        status = "Direct camera feed is working. Install Dory Camera to expose it to other apps."
    }

    private func didStop(_ client: DoryMacGuestCameraClient, error: Error) {
        guard self.client === client else { return }
        streamTask = nil
        self.client = nil
        isRunning = false
        status = "Camera feed stopped: \(String(describing: error))"
    }
}

@MainActor
final class CameraExtensionController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    private enum PendingAction {
        case install
        case remove
    }

    @Published private(set) var status = "Dory Camera is ready to install."
    @Published private(set) var isWorking = false
    private var pendingAction: PendingAction?

    override init() {
        super.init()
        refresh()
    }

    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    func install() {
        guard isInstalledInApplications else {
            status = "Move Dory Guest Tools to Applications before installing Dory Camera."
            return
        }
        isWorking = true
        pendingAction = .install
        status = "Requesting Dory Camera activation…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: cameraExtensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        isWorking = true
        pendingAction = .remove
        status = "Requesting Dory Camera removal…"
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: cameraExtensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func refresh() {
        status = "Checking Dory Camera…"
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: cameraExtensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            status = "Approve Dory Camera in System Settings to finish installation."
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            isWorking = false
            let action = pendingAction
            pendingAction = nil
            if result == .willCompleteAfterReboot {
                status = action == .remove
                    ? "Restart macOS to finish removing Dory Camera."
                    : "Restart macOS to finish updating Dory Camera."
            } else {
                status = action == .remove
                    ? "Dory Camera was removed."
                    : "Dory Camera is installed and available to camera apps."
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            isWorking = false
            pendingAction = nil
            status = "Dory Camera could not be changed: \(error.localizedDescription)"
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            guard let installed = properties.first else {
                status = "Dory Camera is not installed."
                return
            }
            if installed.isUninstalling {
                status = "Dory Camera removal will finish after restart."
            } else if installed.isAwaitingUserApproval {
                status = "Approve Dory Camera in System Settings to finish installation."
            } else if installed.isEnabled {
                status = "Dory Camera \(installed.bundleShortVersion) is installed and enabled."
            } else {
                status = "Dory Camera is installed but not enabled."
            }
        }
    }
}

@main
struct DoryGuestToolsApp: App {
    @StateObject private var cameraExtension = CameraExtensionController()
    @StateObject private var cameraPreview = CameraPreviewController()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 18) {
                Text("Dory Guest Tools")
                    .font(.largeTitle.bold())
                Text("Install Dory Camera so FaceTime, browsers, and other macOS apps in this virtual machine can use the Mac host camera.")
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("Camera feed") {
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack {
                            Color.black
                            if let image = cameraPreview.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                Image(systemName: "video.slash")
                                    .font(.system(size: 38))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 480, height: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text(cameraPreview.status)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Test Camera Feed") { cameraPreview.start() }
                                .buttonStyle(.borderedProminent)
                                .disabled(cameraPreview.isRunning)
                            Button("Stop Test") { cameraPreview.stop() }
                                .disabled(!cameraPreview.isRunning)
                        }
                    }
                    .padding(8)
                }

                Divider()
                if !cameraExtension.isInstalledInApplications {
                    Label("Move this app to Applications first.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(cameraExtension.status)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Install Dory Camera") { cameraExtension.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(cameraExtension.isWorking || !cameraExtension.isInstalledInApplications)
                    Button("Remove") { cameraExtension.uninstall() }
                        .disabled(cameraExtension.isWorking)
                    Button("Refresh") { cameraExtension.refresh() }
                        .disabled(cameraExtension.isWorking)
                }
            }
            .padding(28)
            .frame(width: 560)
        }
        .windowResizability(.contentSize)
    }
}
