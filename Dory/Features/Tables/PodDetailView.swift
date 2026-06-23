import SwiftUI

struct PodDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    @Environment(\.openWindow) private var openWindow
    let pod: Pod
    @State private var logLines: [LogLine] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            logs
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bgContent)
        .task(id: pod.id) {
            logLines = await store.podLogs(pod)
            for await line in store.streamPodLogs(pod) {
                logLines.append(line)
                if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(label: pod.phase.rawValue, color: pod.phase.color(p), background: pod.phase.background(p))
            Text(pod.name).font(.mono(14, weight: .semibold)).foregroundStyle(p.text)
            Text(pod.namespace).font(.system(size: 12)).foregroundStyle(p.text3)
            Spacer()
            Button("Exec") { openWindow(value: store.terminalSession(for: pod)) }
                .buttonStyle(.plain).foregroundStyle(p.accentText)
                .disabled(pod.phase != .running)
                .accessibilityIdentifier("pod-exec")
            Button("Done") { store.selectedPodID = nil }.buttonStyle(.plain).foregroundStyle(p.accentText)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            HStack {
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
            .padding(.horizontal, 16).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                }
                .onChange(of: logLines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("logs-cursor", anchor: .bottom) }
                }
            }
            .background(p.monoBg)
        }
    }
}
