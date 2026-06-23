import SwiftUI

struct DeploymentDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let deployment: KubeDeploymentRow
    @State private var replicas: Int
    @State private var confirmingScale = false
    @State private var confirmingRestart = false

    init(deployment: KubeDeploymentRow) {
        self.deployment = deployment
        _replicas = State(initialValue: deployment.replicas)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bgContent)
        .onChange(of: deployment.replicas) { _, newValue in replicas = newValue }
        .confirmationDialog(
            "Scale \(deployment.name) to \(replicas) replica\(replicas == 1 ? "" : "s")?",
            isPresented: $confirmingScale, titleVisibility: .visible
        ) {
            Button("Scale") { Task { await store.scaleDeployment(deployment, replicas: replicas) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes the desired replica count for this deployment.")
        }
        .confirmationDialog(
            "Restart \(deployment.name)?",
            isPresented: $confirmingRestart, titleVisibility: .visible
        ) {
            Button("Restart") { Task { await store.restartDeployment(deployment) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Triggers a rolling restart of all pods in this deployment.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(deployment.name).font(.mono(14, weight: .semibold)).foregroundStyle(p.text)
            Text(deployment.namespace).font(.system(size: 12)).foregroundStyle(p.text3)
            Text("Ready \(deployment.ready)").font(.system(size: 12)).foregroundStyle(p.text2)
            Spacer()
            Button("Done") { store.selectedDeploymentID = nil }.buttonStyle(.plain).foregroundStyle(p.accentText)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Stepper(value: $replicas, in: 0...50) {
                    Text("Replicas: \(replicas)").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                }
                .fixedSize()
                Button("Apply") { confirmingScale = true }
                    .buttonStyle(DoryButtonStyle(kind: .primary))
                    .disabled(replicas == deployment.replicas)
            }
            Button("Restart Deployment") { confirmingRestart = true }
                .buttonStyle(DoryButtonStyle(kind: .secondary))
        }
        .padding(18)
    }
}
