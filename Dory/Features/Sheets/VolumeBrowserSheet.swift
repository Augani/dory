import SwiftUI

struct VolumeBrowserSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.border)
            if let preview = store.volumeFilePreview {
                filePreview(preview)
            } else {
                fileList
            }
        }
        .frame(minWidth: 520, idealWidth: 660, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
        .background(p.bgContent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Glyph(glyph: .volumes, size: 16, color: p.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.browsingVolume ?? "Volume").font(.system(size: 14, weight: .bold)).foregroundStyle(p.text)
                breadcrumb
            }
            Spacer(minLength: 0)
            if store.volumeBrowseBusy { ProgressView().controlSize(.small) }
            Button("Close") { store.activeSheet = nil }.buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.accentText)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var breadcrumb: some View {
        let components = store.volumeBrowsePath.split(separator: "/").map(String.init)
        return HStack(spacing: 3) {
            Button(store.browsingVolume ?? "Volume") { Task { await store.jumpToVolumePath("") } }
                .buttonStyle(.plain)
                .font(.mono(11, weight: components.isEmpty ? .bold : .medium))
                .foregroundStyle(components.isEmpty ? p.text2 : p.accentText)
            ForEach(Array(components.enumerated()), id: \.offset) { idx, comp in
                Text("/").font(.mono(11)).foregroundStyle(p.text3)
                Button(comp) {
                    let target = components[0...idx].joined(separator: "/")
                    Task { await store.jumpToVolumePath(target) }
                }
                .buttonStyle(.plain)
                .font(.mono(11, weight: idx == components.count - 1 ? .bold : .medium))
                .foregroundStyle(idx == components.count - 1 ? p.text2 : p.accentText)
            }
        }
        .lineLimit(1)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !store.volumeBrowsePath.isEmpty {
                    row(name: "..", isDirectory: true, size: "") { Task { await store.volumeBrowseUp() } }
                }
                ForEach(store.volumeEntries) { entry in
                    HStack(spacing: 0) {
                        row(name: entry.name, isDirectory: entry.isDirectory, size: entry.size) {
                            Task { await store.enterVolumePath(entry) }
                        }
                        if !entry.isDirectory {
                            Button { store.exportVolumeFile(entry) } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 12)).foregroundStyle(p.accentText)
                                    .frame(width: 32, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Export to your Mac…")
                        }
                    }
                    .contextMenu {
                        Button("Copy Path") { store.copyVolumePath(entry) }
                        if !entry.isDirectory { Button("Export to Mac…") { store.exportVolumeFile(entry) } }
                    }
                }
                if store.volumeEntries.isEmpty && !store.volumeBrowseBusy {
                    Text("Empty directory").font(.system(size: 12.5)).foregroundStyle(p.text3).padding(.top, 30)
                }
            }
        }
    }

    private func row(name: String, isDirectory: Bool, size: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Glyph(glyph: isDirectory ? .gridView : .images, size: 14, color: isDirectory ? p.accent : p.text3)
                Text(name).font(.mono(12.5, weight: isDirectory ? .semibold : .regular)).foregroundStyle(p.text).lineLimit(1)
                Spacer(minLength: 0)
                Text(size).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(p.text3)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(p.bgHover)
    }

    private func filePreview(_ content: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.volumeFilePreview = nil } label: {
                    Text("‹ Back").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(p.accentText)
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ScrollView {
                Text(content).font(.mono(11.5, weight: .regular)).foregroundStyle(p.text2)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
    }
}
