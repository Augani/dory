import SwiftUI

struct HealthView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let snapshot = store.healthSnapshot {
                    if snapshot.cliMissing {
                        cliMissingCard
                    } else {
                        summaryCard(snapshot)
                        recoverySection
                        if let idle = snapshot.idle {
                            autoIdleCard(idle)
                        }
                        ForEach(HealthCategory.allCases) { category in
                            let checks = snapshot.checks(in: category)
                            if !checks.isEmpty {
                                categorySection(category, checks)
                            }
                        }
                        if !snapshot.history.isEmpty {
                            historySection(snapshot.history)
                        }
                    }
                } else {
                    loadingCard
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(p.bgContent)
        .task {
            let isStale = store.healthSnapshot.map { Date().timeIntervalSince($0.generatedAt) > 20 } ?? true
            if isStale {
                await store.loadHealth()
            }
        }
    }

    // MARK: Summary

    private func summaryCard(_ snapshot: HealthSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                statusChip(snapshot.passing, .pass)
                statusChip(snapshot.warning, .warn)
                statusChip(snapshot.failing, .fail)
                statusChip(snapshot.skipped, .skip)
                Spacer(minLength: 0)
                if store.healthLoading {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = snapshot.doctorError {
                Text(error)
                    .font(.system(size: 12)).foregroundStyle(p.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let actionError = store.healthActionError {
                Text(actionError)
                    .font(.system(size: 12)).foregroundStyle(p.red)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
            }
            HStack(spacing: 8) {
                actionButton("Refresh", loading: store.healthLoading) {
                    Task { await store.loadHealth() }
                }
                actionButton(snapshot.activeProbed ? "Re-run active probes" : "Run active probes", loading: store.healthActiveLoading) {
                    Task { await store.loadHealth(active: true) }
                }
                if snapshot.failing > 0 {
                    actionButton("Repair", prominent: true, loading: store.healthActionInFlight) {
                        Task { await store.runHealthRepair() }
                    }
                }
                Spacer(minLength: 0)
                Text("Active probes start a tiny throwaway container to test DNS, ports, and mounts.")
                    .font(.system(size: 11)).foregroundStyle(p.text3)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
            }
        }
        .cardStyle(p)
    }

    // MARK: Recovery

    private var recoveryActions: [(target: String, title: String)] {
        [
            ("socket", "Rebuild socket"),
            ("context", "Fix docker context"),
            ("dns", "Flush DNS"),
            ("routes", "Refresh routes"),
            ("domains", "Refresh domains"),
            ("ports", "Reforward ports"),
            ("dockerd", "Restart dockerd"),
            ("guest-agent", "Wake guest agent"),
        ]
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("RECOVERY ACTIONS")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(recoveryActions, id: \.target) { action in
                    Button {
                        Task { await store.runRepairTarget(action.target) }
                    } label: {
                        Text(action.title)
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(p.bgInput, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.healthActionInFlight)
                    .accessibilityIdentifier("recover-\(action.target)")
                }
            }
            Text("Each action repairs one subsystem in place — no VM restart, no lost containers or volumes.")
                .font(.system(size: 11)).foregroundStyle(p.text3)
        }
    }

    private func statusChip(_ count: Int, _ status: HealthStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(status)).frame(width: 8, height: 8)
            Text("\(count)").font(.system(size: 15, weight: .bold)).foregroundStyle(p.text)
            Text(statusPlural(status)).font(.system(size: 11.5)).foregroundStyle(p.text3)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(weak(status), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Auto-Idle

    private func autoIdleCard(_ idle: IdleStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(idle.canSleep ? p.text3 : p.green).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Why is Dory awake?").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                    Text(autoIdleSummary(idle)).font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(2)
                }
                Spacer(minLength: 0)
                Text(idle.mode.replacingOccurrences(of: "-", with: " ").capitalized)
                    .font(.system(size: 10.5, weight: .bold)).foregroundStyle(p.text3)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(p.bgInput, in: Capsule())
            }
            if !idle.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(idle.blockers.enumerated()), id: \.offset) { _, blocker in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(p.amber).frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(blocker.humanType).font(.system(size: 12, weight: .medium)).foregroundStyle(p.text)
                                if !blocker.detail.isEmpty {
                                    Text(blocker.detail).font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 2)
            } else {
                Text("No blockers — the engine is safe to sleep.")
                    .font(.system(size: 12)).foregroundStyle(p.text2)
            }
            if let proxy = idle.proxyState, let state = proxy.state, state != "unknown" {
                Text("Proxy: \(state)\(proxy.detail.map { " — \($0)" } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(p.text3).lineLimit(2)
            }
            if store.canRestartEngineForHealth {
                HStack(spacing: 8) {
                    actionButton("Restart engine", loading: store.healthActionInFlight) {
                        Task { await store.restartEngineForHealth() }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .cardStyle(p)
    }

    // MARK: Category sections

    private func categorySection(_ category: HealthCategory, _ checks: [DoctorCheck]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel(category.rawValue.uppercased())
            VStack(spacing: 0) {
                ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                    if index > 0 {
                        Divider().overlay(p.border)
                    }
                    checkRow(check)
                }
            }
            .cardStyle(p, padding: 4)
        }
    }

    private func checkRow(_ check: DoctorCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color(check.health)).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                Text(check.detail).font(.system(size: 11.5)).foregroundStyle(p.text3).lineLimit(3)
                if let action = check.action, !action.isEmpty {
                    Text(action).font(.system(size: 11.5, weight: .medium)).foregroundStyle(p.accentText).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            statusBadge(check.health)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: History

    private func historySection(_ history: [IdleHistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            groupLabel("RECENT AUTO-IDLE ACTIVITY")
            VStack(spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.offset) { index, entry in
                    if index > 0 {
                        Divider().overlay(p.border)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.state.replacingOccurrences(of: "-", with: " "))
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(p.text2)
                            .frame(width: 120, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            if let detail = entry.detail, !detail.isEmpty {
                                Text(detail).font(.system(size: 12)).foregroundStyle(p.text).lineLimit(2)
                            }
                            Text(entry.at).font(.system(size: 10.5)).foregroundStyle(p.text3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                }
            }
            .cardStyle(p, padding: 4)
        }
    }

    // MARK: Empty states

    private var loadingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Running diagnostics…").font(.system(size: 13)).foregroundStyle(p.text2)
            Spacer(minLength: 0)
        }
        .cardStyle(p)
    }

    private var cliMissingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics CLI unavailable")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
            Text("The `dory` helper was not found in the app bundle or on PATH. Install Dory's shell integration, or set DORY_CLI to the dory script, to see engine, networking, file-sharing, disk, and compatibility health here.")
                .font(.system(size: 12.5)).foregroundStyle(p.text2).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            actionButton("Retry", loading: store.healthLoading) {
                Task { await store.loadHealth() }
            }
        }
        .cardStyle(p)
    }

    // MARK: Reusable pieces

    private func statusBadge(_ status: HealthStatus) -> some View {
        Text(status.label.uppercased())
            .font(.system(size: 10, weight: .bold)).tracking(0.4)
            .foregroundStyle(color(status))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(weak(status), in: Capsule())
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
    }

    private func actionButton(_ label: String, prominent: Bool = false, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading { ProgressView().controlSize(.mini) }
                Text(label).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(prominent ? .white : p.text)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(prominent ? p.accent : p.bgInput, in: RoundedRectangle(cornerRadius: 7))
            .overlay(prominent ? nil : RoundedRectangle(cornerRadius: 7).strokeBorder(p.border))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private func color(_ status: HealthStatus) -> Color {
        switch status {
        case .pass: p.green
        case .warn: p.amber
        case .fail: p.red
        case .skip: p.text3
        }
    }

    private func weak(_ status: HealthStatus) -> Color {
        switch status {
        case .pass: p.greenWeak
        case .warn: p.amberWeak
        case .fail: p.redWeak
        case .skip: p.pill
        }
    }

    private func statusPlural(_ status: HealthStatus) -> String {
        switch status {
        case .pass: "passing"
        case .warn: "warnings"
        case .fail: "failing"
        case .skip: "skipped"
        }
    }

    private func autoIdleSummary(_ idle: IdleStatus) -> String {
        if !idle.autoIdleEnabled {
            return "Auto-Idle is off (mode: \(idle.mode)). The engine stays resident until stopped."
        }
        if idle.canSleep {
            let minutes = idle.sleepAfterMinutes.map { " after \($0)m idle" } ?? ""
            return "No active workloads — the engine may sleep\(minutes)."
        }
        return "\(idle.blockers.count) workload\(idle.blockers.count == 1 ? "" : "s") keeping the engine awake."
    }
}

private extension View {
    func cardStyle(_ p: DoryPalette, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(p.border))
    }
}
