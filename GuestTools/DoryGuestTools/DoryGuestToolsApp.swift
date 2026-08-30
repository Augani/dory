import SwiftUI
import SystemExtensions

private let cameraExtensionIdentifier = "com.pythonxi.Dory.GuestTools.CameraExtension"

@MainActor
final class CameraExtensionController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var status = "Dory Camera is ready to install."
    @Published private(set) var isWorking = false

    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications"
    }

    func install() {
        guard isInstalledInApplications else {
            status = "Move Dory Guest Tools to Applications before installing Dory Camera."
            return
        }
        isWorking = true
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
        status = "Requesting Dory Camera removal…"
        let request = OSSystemExtensionRequest.deactivationRequest(
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
            status = result == .willCompleteAfterReboot
                ? "Restart macOS to finish updating Dory Camera."
                : "Dory Camera is installed and available to camera apps."
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            isWorking = false
            status = "Dory Camera could not be changed: \(error.localizedDescription)"
        }
    }
}

@main
struct DoryGuestToolsApp: App {
    @StateObject private var cameraExtension = CameraExtensionController()

    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 18) {
                Text("Dory Guest Tools")
                    .font(.largeTitle.bold())
                Text("Install Dory Camera so FaceTime, browsers, and other macOS apps in this virtual machine can use the Mac host camera.")
                    .fixedSize(horizontal: false, vertical: true)
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
                }
            }
            .padding(28)
            .frame(width: 520)
        }
        .windowResizability(.contentSize)
    }
}
