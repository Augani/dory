import SwiftUI

struct ContainerDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.openWindow) private var openWindow
    let container: Container
    @State private var logLines: [LogLine] = []
    @State private var envVars: [EnvVar] = []
    @State private var liveCPU: Double?
    @State private var cpuHistory: [Double] = []
    @State private var confirmingDelete = false

    private var sparkData: [Double] { ContainerStatsFormat.cpuSparkBars(cpuHistory) }

    private var displayCPU: Double { liveCPU ?? container.cpuPercent }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                actions.padding(.top, 14)
                tabs.padding(.top, 14)
            }
            .padding(.horizontal, 18).padding(.top, 16)

            ScrollView {
                tabContent
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: container.id) {
            liveCPU = nil
            cpuHistory = []
            envVars = await store.fetchEnv(container.id)
            while !Task.isCancelled {
                // Read the live container state so polling reflects start/stop instead of the
                // snapshot captured when the task began.
                let isRunning = store.containers.first(where: { $0.id == container.id })?.isRunning ?? container.isRunning
                let sample: Double
                if isRunning { sample = await store.sampleCPU(container.id) ?? container.cpuPercent; liveCPU = sample }
                else { sample = 0; liveCPU = 0 }
                cpuHistory.append(sample)
                if cpuHistory.count > 30 { cpuHistory.removeFirst() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: "\(container.id)|\(store.detailTab == .logs)") {
            logLines = []
            guard store.detailTab == .logs else { return }
            logLines = await store.fetchLogs(container.id)
            for await line in store.streamLogs(container.id) {
                logLines.append(line)
                if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: container.status.dotColor(p), size: 9).padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name).font(.system(size: 17, weight: .bold)).foregroundStyle(p.text)
                Text(container.image).font(.mono(12)).foregroundStyle(p.text3)
            }
            Spacer(minLength: 0)
            StatusPill(container.status)
        }
    }

    private var actions: some View {
        HStack(spacing: 7) {
            Button(container.isRunning ? "Stop" : "Start") { store.toggle(container) }
                .buttonStyle(DoryButtonStyle(kind: .secondary))
            Button("Restart") { store.restart(container) }
                .buttonStyle(DoryButtonStyle(kind: .secondary))
            Spacer(minLength: 0)
            Menu {
                Button("Open Terminal") { openWindow(value: store.terminalSession(for: container)) }
                    .disabled(!container.isRunning)
                Button("Copy Container ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(container.id, forType: .string)
                }
                Divider()
                Button("Delete Container", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(p.text2)
                    .frame(width: 32, height: 30)
                    .background(p.bgElevated, in: RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue))
                    .overlay(RoundedRectangle(cornerRadius: DoryRadius.sm.rawValue).strokeBorder(p.border))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("container-menu")
        }
        .confirmationDialog("Delete \(container.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.remove(container) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the container. This cannot be undone.")
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(DetailTab.allCases) { tab in
                let selected = store.detailTab == tab
                Button { store.detailTab = tab } label: {
                    Text(tab.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? p.text : p.text3)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? p.accent : Color.clear).frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    @ViewBuilder private var tabContent: some View {
        switch store.detailTab {
        case .overview: overview
        case .stats: stats
        case .logs: logs
        case .terminal: terminal
        case .env: env
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                statCard("CPU", String(format: "%.1f%%", displayCPU))
                statCard("MEMORY", container.memoryDisplay)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("DETAILS").font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
                    .padding(.bottom, 8)
                ForEach(store.overviewRows(for: container), id: \.key) { row in
                    HStack(spacing: 12) {
                        Text(row.key).font(.system(size: 12.5)).foregroundStyle(p.text3)
                        Spacer(minLength: 0)
                        Text(row.value).font(.mono(12.5)).foregroundStyle(p.text).multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
                }
            }
        }
    }

    private func statCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(p.text3)
            Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(p.text)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(p.border))
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(store.statMetrics(for: container)) { metric in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(metric.label).font(.system(size: 12, weight: .medium)).foregroundStyle(p.text2)
                        Spacer()
                        Text(metric.value).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(p.text)
                    }
                    ThinBar(fraction: metric.fraction, tint: metric.tint, height: 6)
                }
            }
            VStack(spacing: 8) {
                Group {
                    if cpuHistory.isEmpty {
                        Text("Collecting CPU…").font(.system(size: 11)).foregroundStyle(p.text3)
                            .frame(maxWidth: .infinity, minHeight: 84)
                    } else {
                        SparkBars(heights: sparkData, tint: p.accent).frame(height: 84)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(p.bgElevated, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
                Text("CPU usage · last 60s").font(.system(size: 11)).foregroundStyle(p.text3)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("OUTPUT").font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(p.text3)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ContainerStatsFormat.logsPlainText(logLines), forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                        Text("Copy").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(p.text3)
                }
                .buttonStyle(.plain)
                .disabled(logLines.isEmpty)
            }
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(logLines) { line in
                        HStack(spacing: 6) {
                            Text(line.timestamp).foregroundStyle(Color(hex: 0x5B6070))
                            Text(line.level.rawValue).font(.mono(11.5, weight: .bold)).foregroundStyle(line.level.color(p))
                            Text(line.message).foregroundStyle(p.monoText)
                            Spacer(minLength: 0)
                        }
                        .font(.mono(11.5)).lineLimit(1).padding(.vertical, 1.5)
                        .id(line.id)
                    }
                    HStack(spacing: 6) {
                        Text("$").foregroundStyle(p.green)
                        BlinkingCursor()
                    }
                    .font(.mono(11.5)).padding(.top, 2).id("logs-cursor")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background(p.monoBg, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: logLines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("logs-cursor", anchor: .bottom) }
                }
            }
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Interactive shell").font(.system(size: 12.5)).foregroundStyle(p.text3)
                Spacer()
                Button { openWindow(value: store.terminalSession(for: container)) } label: {
                    Text("Pop out ↗").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                }
                .buttonStyle(.plain)
                Button { store.openContainerTerminal(container) } label: {
                    Text("Open in Terminal.app ↗").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.accentText)
                }
                .buttonStyle(.plain)
                .disabled(!container.isRunning)
                .accessibilityIdentifier("open-terminal")
            }
            if container.isRunning {
                ContainerTerminalView(socketPath: store.shimSocketPath, containerID: container.id)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(p.border))
                    .id(container.id)
            } else {
                Text("Start the container to open a shell.")
                    .font(.system(size: 12)).foregroundStyle(p.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(p.monoBg, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var env: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(envVars) { variable in
                VStack(alignment: .leading, spacing: 1) {
                    Text(variable.key).font(.mono(11, weight: .bold)).foregroundStyle(p.accentText)
                    Text(variable.value).font(.mono(12)).foregroundStyle(p.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
            }
        }
    }
}

struct BlinkingCursor: View {
    @Environment(\.palette) private var p
    @State private var visible = true
    var body: some View {
        Rectangle()
            .fill(p.monoText)
            .frame(width: 7, height: 13)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.linear(duration: 0.55).repeatForever(autoreverses: true)) { visible = false }
            }
    }
}
