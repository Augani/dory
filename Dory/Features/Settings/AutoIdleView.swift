import SwiftUI

struct AutoIdleView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private let modes: [(id: String, title: String, detail: String)] = [
        ("always-on", "Always On", "Dory starts the engine when the app opens and keeps it running."),
        ("auto-idle", "Auto-Idle", "Dory starts on app open; doryd sleeps it after idle time."),
        ("battery-saver", "Battery Saver", "Auto-Idle with the same blockers and sleep policy."),
        ("manual", "Manual Stop", "Dory keeps the engine running until you stop it."),
    ]

    private let sleepChoices = [5, 15, 30, 60]

    private var policyEditable: Bool {
        store.runtimeMode == "auto-idle" || store.runtimeMode == "battery-saver"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                groupLabel("RUNTIME MODE")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(modes, id: \.id) { mode in
                        modeCard(mode)
                    }
                }

                groupLabel("IDLE POLICY")
                VStack(spacing: 0) {
                    sleepAfterRow
                    Divider().overlay(p.border)
                    toggleRow("Keep published ports awake",
                              "Do not sleep while a container publishes a port a browser or client may use.",
                              key: "keepPublishedPortsAwake", value: store.idlePolicy.keepPublishedPortsAwake, divider: true)
                    toggleRow("Keep pinned projects awake",
                              "Honor io.dory.keep-awake labels so pinned services never sleep.",
                              key: "keepPinnedProjectsAwake", value: store.idlePolicy.keepPinnedProjectsAwake, divider: true)
                    toggleRow("Keep Kubernetes awake",
                              "Do not sleep while a Kubernetes cluster is configured.",
                              key: "keepKubernetesAwake", value: store.idlePolicy.keepKubernetesAwake, divider: true)
                    toggleRow("Show wake notifications",
                              "Print a line when doryd wakes a sleeping engine for Docker use.",
                              key: "showWakeNotifications", value: store.idlePolicy.showWakeNotifications, divider: false)
                }
                .cardSurface(p)
                .opacity(policyEditable ? 1 : 0.55)
                .allowsHitTesting(policyEditable)

                if !policyEditable {
                    Text("Idle policy applies in Auto-Idle and Battery Saver modes.")
                        .font(.system(size: 11.5)).foregroundStyle(p.text3)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.loadIdlePolicy() }
    }

    private func modeCard(_ mode: (id: String, title: String, detail: String)) -> some View {
        let selected = store.runtimeMode == mode.id
        return Button {
            Task { await store.setRuntimeMode(mode.id) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(selected ? p.accent : p.text3).frame(width: 8, height: 8)
                    Text(mode.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                }
                Text(mode.detail).font(.system(size: 11.5)).foregroundStyle(p.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? p.accent : p.border, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .disabled(store.idlePolicyBusy)
        .accessibilityIdentifier("idle-mode-\(mode.id)")
    }

    private var sleepAfterRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Sleep after idle").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Text("How long with no Docker activity before doryd sleeps the engine.")
                    .font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(sleepChoices, id: \.self) { minutes in
                    let selected = store.idlePolicy.sleepAfterMinutes == minutes
                    Button {
                        Task { await store.setIdleSleepAfter(minutes) }
                    } label: {
                        Text("\(minutes)m")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? .white : p.text2)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(selected ? p.accent : p.bgInput, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(selected ? nil : RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("idle-sleep-\(minutes)")
                }
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
    }

    private func toggleRow(_ title: String, _ subtitle: String, key: String, value: Bool, divider: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(p.text3)
            }
            Spacer(minLength: 0)
            DoryToggle(isOn: Binding(get: { value }, set: { on in Task { await store.setIdleFlag(key, on) } }))
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .overlay(alignment: .bottom) { if divider { Rectangle().fill(p.border).frame(height: 1) } }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
    }
}

private extension View {
    func cardSurface(_ p: DoryPalette) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }
}
