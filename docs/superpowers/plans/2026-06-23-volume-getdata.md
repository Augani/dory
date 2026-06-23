# Volume Browser "Get Your Data Out" Implementation Plan (WS5 volumes)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Governing spec: audit digest `docs/superpowers/specs/2026-06-22-ui-redesign-audit-digest.md` §3 WS5 (volume browser) + §6 cut (drag-drop deferred; explicit Export/Copy actions in-scope).

**Goal:** Turn the read-only volume browser into one you can get data out of — export a file to your Mac, copy its in-volume path, and navigate with breadcrumbs in a resizable window.

**Architecture:** Exports go through the Docker archive endpoint (`GET /containers/{id}/archive`, the same mechanism as `docker cp`) against the existing throwaway read-only helper container, so it is backend-agnostic and binary-safe. A pure `extractSingleFileFromTar` parses the returned tar and is unit-tested. `AppStore` gains `exportVolumeFile` (NSSavePanel + write), `copyVolumePath`, and `jumpToVolumePath` (breadcrumb nav). The sheet gets a clickable breadcrumb, per-row Export/Copy actions, and a resizable frame.

**Tech Stack:** Swift 6 / SwiftUI / macOS.

## Global Constraints

- Build ONLY with `scripts/build.sh`; test ONLY with `scripts/test.sh` (Xcode 27 beta `DEVELOPER_DIR`). `BUILD SUCCEEDED` / `xcodebuild_exit=0` is authoritative. Never call `xcodebuild` directly. Minutes per run.
- IGNORE SourceKit/IDE diagnostics — always false positives in this project.
- Synchronized Xcode folders — new `.swift` under `DoryTests/` auto-includes; no `Dory.xcodeproj/project.pbxproj` edits.
- No inline comments; no docstrings. Colors via `Environment(\.palette)` (`p`) / `store.palette`.
- `HTTPResponse` exposes `body: Data`, `statusCode: Int`, `isSuccess: Bool`. The volume helper pattern (create alpine container, `Binds:["<volume>:/data:ro"]`, run, delete) already exists in `VolumeBrowser`. Tests use **Swift Testing** (`import Testing`, `@Test func`, `#expect`).

---

### Task V1: Binary-safe file export (runtime + store + tests)

**Files:**
- Modify: `Dory/Runtime/Volumes/VolumeBrowser.swift` (add `exportFile` + pure `extractSingleFileFromTar` + `parseOctalSize`)
- Modify: `Dory/Models/AppStore.swift` (add `exportVolumeFile`, `copyVolumePath`, `jumpToVolumePath`)
- Create: `DoryTests/VolumeBrowserTests.swift`

**Interfaces:**
- Produces: `VolumeBrowser.exportFile(volume:path:) async -> Data?`, `static VolumeBrowser.extractSingleFileFromTar(_ data: Data) -> Data?`; `AppStore.exportVolumeFile(_:)`, `AppStore.copyVolumePath(_:)`, `AppStore.jumpToVolumePath(_:) async`.
- Consumes: existing `VolumeBrowser.safePath`, `decodeId`, `helperImage`, `runtime.proxyRequest`, `runtime.pull`; existing `volumeBrowsePath`/`browsingVolume`/`volumeBrowseBusy`/`refreshVolumeBrowser`/`actionError`.

- [ ] **Step 1: Write the failing tar-extraction tests**

Create `DoryTests/VolumeBrowserTests.swift`:
```swift
import Testing
import Foundation
@testable import Dory

struct VolumeBrowserTests {
    private func makeTar(name: String, content: [UInt8]) -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        for (i, b) in Array(name.utf8).prefix(100).enumerated() { header[i] = b }
        let sizeOctal = Array(String(format: "%011o", content.count).utf8)
        for (i, b) in sizeOctal.enumerated() { header[124 + i] = b }
        header[156] = UInt8(ascii: "0")
        var tar = header + content
        let pad = (512 - content.count % 512) % 512
        tar += [UInt8](repeating: 0, count: pad)
        tar += [UInt8](repeating: 0, count: 1024)
        return Data(tar)
    }

    @Test func extractsRegularFileContent() {
        let content = Array("hi there".utf8)
        let tar = makeTar(name: "hello.txt", content: content)
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data(content))
    }

    @Test func extractsEmptyFile() {
        let tar = makeTar(name: "empty", content: [])
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data())
    }

    @Test func extractsBinaryContentLosslessly() {
        let content: [UInt8] = [0x00, 0xFF, 0x10, 0x80, 0x00, 0x7F]
        let tar = makeTar(name: "bin.dat", content: content)
        #expect(VolumeBrowser.extractSingleFileFromTar(tar) == Data(content))
    }

    @Test func returnsNilForShortData() {
        #expect(VolumeBrowser.extractSingleFileFromTar(Data([1, 2, 3])) == nil)
    }

    @Test func returnsNilForAllZeroData() {
        #expect(VolumeBrowser.extractSingleFileFromTar(Data(count: 1024)) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `scripts/test.sh -only-testing:DoryTests/VolumeBrowserTests`
Expected: FAIL (compile error — `extractSingleFileFromTar` not defined).

- [ ] **Step 3: Implement the tar extractor**

In `Dory/Runtime/Volumes/VolumeBrowser.swift`, add to the `VolumeBrowser` struct:
```swift
    static func extractSingleFileFromTar(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let block = 512
        var offset = 0
        while offset + block <= bytes.count {
            let header = bytes[offset..<offset + block]
            if header.allSatisfy({ $0 == 0 }) { return nil }
            let typeflag = bytes[offset + 156]
            guard let size = parseOctalSize(bytes[(offset + 124)..<(offset + 136)]) else { return nil }
            let contentStart = offset + block
            let contentEnd = contentStart + size
            guard contentEnd <= bytes.count else { return nil }
            if typeflag == UInt8(ascii: "0") || typeflag == 0 {
                return Data(bytes[contentStart..<contentEnd])
            }
            let padded = ((size + block - 1) / block) * block
            offset = contentStart + padded
        }
        return nil
    }

    private static func parseOctalSize(_ field: ArraySlice<UInt8>) -> Int? {
        let str = String(decoding: Array(field), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \u{0}"))
        if str.isEmpty { return 0 }
        return Int(str, radix: 8)
    }
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `scripts/test.sh -only-testing:DoryTests/VolumeBrowserTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Implement `exportFile` (impure, build-verified)**

In `VolumeBrowser.swift`, add to the struct (it can use the private `decodeId`/`safePath`/`helperImage`):
```swift
    func exportFile(volume: String, path: String) async -> Data? {
        let target = Self.safePath(path)
        try? await runtime.pull(image: Self.helperImage)
        let body = Data("{\"Image\":\"\(Self.helperImage)\",\"Cmd\":[\"true\"],\"HostConfig\":{\"Binds\":[\"\(volume):/data:ro\"]}}".utf8)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create",
            headers: [(name: "Content-Type", value: "application/json")], body: body),
            let id = decodeId(create.body) else { return nil }
        defer {
            let runtime = self.runtime
            Task { _ = await runtime.proxyRequest(method: "DELETE", path: "/containers/\(id)?force=true", headers: [], body: Data()) }
        }
        _ = await runtime.proxyRequest(method: "POST", path: "/containers/\(id)/start", headers: [], body: Data())
        _ = await runtime.proxyRequest(method: "POST", path: "/containers/\(id)/wait", headers: [], body: Data())
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target
        guard let archive = await runtime.proxyRequest(method: "GET", path: "/containers/\(id)/archive?path=\(encoded)",
            headers: [], body: Data()), archive.isSuccess else { return nil }
        return Self.extractSingleFileFromTar(archive.body)
    }
```

- [ ] **Step 6: Add the AppStore actions**

In `Dory/Models/AppStore.swift`, near the other volume-browse methods (`enterVolumePath`/`volumeBrowseUp`/`refreshVolumeBrowser`), add:
```swift
    func copyVolumePath(_ entry: VolumeEntry) {
        let path = volumeBrowsePath.isEmpty ? "/\(entry.name)" : "/\(volumeBrowsePath)/\(entry.name)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func exportVolumeFile(_ entry: VolumeEntry) {
        guard let volume = browsingVolume, !entry.isDirectory else { return }
        let relativePath = volumeBrowsePath.isEmpty ? entry.name : "\(volumeBrowsePath)/\(entry.name)"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        volumeBrowseBusy = true
        Task {
            let data = await VolumeBrowser(runtime: runtime).exportFile(volume: volume, path: relativePath)
            volumeBrowseBusy = false
            guard let data else { actionError = "Could not export \(entry.name)"; return }
            do { try data.write(to: url) } catch { actionError = "Could not save file: \(error.localizedDescription)" }
        }
    }

    func jumpToVolumePath(_ path: String) async {
        volumeBrowsePath = path
        volumeFilePreview = nil
        await refreshVolumeBrowser()
    }
```
(If `NSSavePanel`/`NSPasteboard` do not resolve, add `import AppKit` at the top of `AppStore.swift`.)

- [ ] **Step 7: Build + full targeted test**

Run: `scripts/build.sh` → expect `BUILD SUCCEEDED`.
Run: `scripts/test.sh -only-testing:DoryTests/VolumeBrowserTests` → expect PASS.

- [ ] **Step 8: Commit**

```bash
git add Dory/Runtime/Volumes/VolumeBrowser.swift Dory/Models/AppStore.swift DoryTests/VolumeBrowserTests.swift
git commit -m "feat(volumes): binary-safe file export via tar archive + copy-path + breadcrumb nav action"
```

---

### Task V2: Browser UI — breadcrumbs, row actions, resizable window

**Files:**
- Modify: `Dory/Features/Sheets/VolumeBrowserSheet.swift`

**Interfaces:**
- Consumes: `AppStore.exportVolumeFile`, `copyVolumePath`, `jumpToVolumePath` (from V1); existing `volumeEntries`/`volumeBrowsePath`/`browsingVolume`/`enterVolumePath`/`volumeBrowseUp`/`volumeFilePreview`.

- [ ] **Step 1: Make the sheet resizable**

In `VolumeBrowserSheet.swift`, replace the fixed frame:
```swift
        .frame(width: 560, height: 460)
```
with:
```swift
        .frame(minWidth: 520, idealWidth: 660, maxWidth: .infinity, minHeight: 420, idealHeight: 560, maxHeight: .infinity)
```

- [ ] **Step 2: Replace the static path with a clickable breadcrumb**

In `header`, replace the path subtitle:
```swift
                Text("/\(store.volumeBrowsePath)").font(.mono(11, weight: .medium)).foregroundStyle(p.text3).lineLimit(1)
```
with:
```swift
                breadcrumb
```
Add the `breadcrumb` view to the struct:
```swift
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
```

- [ ] **Step 3: Add per-row Export / Copy actions**

In `fileList`, replace the entries `ForEach`:
```swift
                ForEach(store.volumeEntries) { entry in
                    row(name: entry.name, isDirectory: entry.isDirectory, size: entry.size) {
                        Task { await store.enterVolumePath(entry) }
                    }
                }
```
with:
```swift
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
```
In the `row` helper, make the row button fill the available width so the export icon sits flush right: change the row's content modifier line
```swift
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
```
to
```swift
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
```

- [ ] **Step 4: Build**

Run: `scripts/build.sh`
Expected: `BUILD SUCCEEDED`. (`square.and.arrow.down` is an SF Symbol; `p.text2`/`p.accentText`/`p.text3` are existing tokens.)

- [ ] **Step 5: Visual check (best-effort)**

Run: `scripts/shots.sh` (best-effort — the browser sheet may not be snapshot-reachable; build is the gate). If reachable, confirm the breadcrumb renders and file rows show the export icon.

- [ ] **Step 6: Commit**

```bash
git add Dory/Features/Sheets/VolumeBrowserSheet.swift
git commit -m "feat(volumes): breadcrumb nav + per-row Export/Copy actions + resizable browser"
```

---

## Self-review notes (addressed)

- **Spec coverage (WS5 §3/§61-64 + §6):** get-your-data-out file actions (V1 export via tar archive — binary-safe; copy-path), breadcrumbs replacing single-level `..` (V2), resizable browser (V2). Drag-drop is the §6-deferred finesse (out). "Reveal in Finder" is intentionally omitted — VM-backed named volumes have no host path; Export-to-Mac is the honest equivalent.
- **Type consistency:** `exportFile`/`extractSingleFileFromTar` signatures match the AppStore call; `VolumeEntry.isDirectory`/`.name` are existing; `HTTPResponse.body/.isSuccess` used per the codec; the `row`/`fileList` edits keep the existing `row(name:isDirectory:size:action:)` signature.
- **Correctness:** the tar extractor is unit-tested for text, empty, binary-lossless, short-data, and all-zero inputs. Export runs against the existing read-only helper, so the volume is never mutated.
- Build + targeted-test verified.
