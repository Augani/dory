import SwiftUI

struct BuildsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    private var records: [BuildActivityRecord] {
        let query = store.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.buildActivity }
        return store.buildActivity.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.status.localizedCaseInsensitiveContains(query)
                || $0.ref.localizedCaseInsensitiveContains(query)
        }
    }

    private var activeCount: Int { store.buildActivity.filter(\.isActive).count }

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider().overlay(p.border)
            if let error = store.buildActivityError, store.buildActivity.isEmpty {
                unavailable(error)
            } else if records.isEmpty {
                empty
            } else {
                HSplitView {
                    history
                        .frame(minWidth: 430, idealWidth: 560)
                    logs
                        .frame(minWidth: 320, idealWidth: 460)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshBuildActivity()
                try? await Task.sleep(for: .seconds(activeCount > 0 || store.doryBuildActive ? 2 : 8))
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            fact("ACTIVE", "\(activeCount)", activeCount > 0 ? p.accent : p.text)
            fact("CACHE", DockerFormat.bytes(store.buildCacheUsage.totalBytes), p.text)
            fact("RECLAIMABLE", DockerFormat.bytes(store.buildCacheUsage.reclaimableBytes), p.green)
            fact("CACHE RECORDS", "\(store.buildCacheUsage.records)", p.text)
            Spacer(minLength: 10)
            if store.doryBuildActive {
                Button("Cancel Dory Build") { store.cancelDoryBuild() }
                    .buttonStyle(DoryButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("cancel-dory-build")
            }
            Button {
                Task { await store.refreshBuildActivity() }
            } label: {
                if store.buildActivityLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(DoryButtonStyle(kind: .secondary))
            .disabled(store.buildActivityLoading)
            .help("Refresh build activity")
            .accessibilityIdentifier("refresh-build-activity")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(p.bgElevated)
    }

    private func fact(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
            Text(value).font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(color)
        }
        .frame(minWidth: 76, alignment: .leading)
    }

    private var history: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(records) { record in
                    Button {
                        Task { await store.loadBuildLogs(record) }
                    } label: {
                        row(record)
                    }
                    .buttonStyle(.plain)
                    .background(store.selectedBuildReference == record.ref ? p.accentWeak : Color.clear)
                    .accessibilityIdentifier("build-\(record.ref)")
                }
            }
        }
        .background(p.bgContent)
    }

    private func row(_ record: BuildActivityRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(color: statusColor(record), size: 8)
                Text(record.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(record.status).font(.system(size: 10.5, weight: .bold)).foregroundStyle(statusColor(record))
            }
            HStack(spacing: 12) {
                Text("\(record.completedSteps)/\(record.totalSteps) steps")
                Text("\(record.cachedSteps) cached")
                Text(duration(record.elapsed()))
                Spacer(minLength: 4)
                Text(relative(record.createdAt))
            }
            .font(.system(size: 10.5)).foregroundStyle(p.text3).monospacedDigit()
            ProgressView(value: record.progress)
                .tint(record.isActive ? p.accent : statusColor(record))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BUILD LOG").font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
                    Text(selected?.name ?? "Select a build")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.text).lineLimit(1)
                }
                Spacer()
                if let selected, selected.isActive, !store.doryBuildActive {
                    Text("Cancel from the originating client")
                        .font(.system(size: 10.5)).foregroundStyle(p.amber)
                }
            }
            .padding(14)
            .background(p.bgElevated)
            .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            Group {
                if store.selectedBuildLogsLoading {
                    ProgressView("Loading retained BuildKit log…").controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if selected == nil {
                    Text("Choose a retained or active build to inspect its bounded local log, step timing, and cache reuse.")
                        .font(.system(size: 12)).foregroundStyle(p.text3).multilineTextAlignment(.center)
                        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(store.selectedBuildLogs)
                            .font(.mono(11)).foregroundStyle(p.monoText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .background(p.monoBg)
                }
            }
        }
    }

    private var selected: BuildActivityRecord? {
        guard let ref = store.selectedBuildReference else { return nil }
        return store.buildActivity.first { $0.ref == ref }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer").font(.system(size: 30)).foregroundStyle(p.text3)
            Text(store.filter.isEmpty ? "No BuildKit history yet" : "No matching builds")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
            Text("Build with Dory's bundled Docker/Buildx tools. Active and retained records appear here without wrapping or changing your command.")
                .font(.system(size: 12)).foregroundStyle(p.text3).multilineTextAlignment(.center)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(p.amber)
            Text("Build activity unavailable").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.text)
            Text(error).font(.system(size: 12)).foregroundStyle(p.text3).multilineTextAlignment(.center).textSelection(.enabled)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusColor(_ record: BuildActivityRecord) -> Color {
        if record.isActive { return p.accent }
        if record.succeeded { return p.green }
        let value = record.status.lowercased()
        return value.contains("cancel") ? p.amber : p.red
    }

    private func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
