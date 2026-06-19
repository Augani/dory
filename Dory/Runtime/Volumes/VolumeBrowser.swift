import Foundation

struct VolumeEntry: Identifiable, Sendable, Hashable {
    var name: String
    var isDirectory: Bool
    var size: String
    var id: String { name }
}

/// Browses files inside a named volume — OrbStack lets you inspect volume contents from the GUI.
/// Mounts the volume read-only into a throwaway helper container in the shared VM and lists/reads
/// through it, so no host-side mount or privileged access is needed.
struct VolumeBrowser: Sendable {
    let runtime: any ContainerRuntime
    static let helperImage = "alpine"

    func list(volume: String, path: String) async -> [VolumeEntry] {
        let target = Self.safePath(path)
        let output = await runHelper(volume: volume, cmd: ["sh", "-c", "ls -lA --full-time \(target) 2>/dev/null"])
        return Self.parseListing(output)
    }

    func read(volume: String, path: String, maxBytes: Int = 65_536) async -> String? {
        let target = Self.safePath(path)
        let output = await runHelper(volume: volume, cmd: ["sh", "-c", "head -c \(maxBytes) \(target) 2>/dev/null"])
        return output.isEmpty ? nil : output
    }

    private func runHelper(volume: String, cmd: [String]) async -> String {
        try? await runtime.pull(image: Self.helperImage)
        let cmdJSON = cmd.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
        let body = Data("{\"Image\":\"\(Self.helperImage)\",\"Cmd\":[\(cmdJSON)],\"HostConfig\":{\"Binds\":[\"\(volume):/data:ro\"]}}".utf8)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create",
            headers: [(name: "Content-Type", value: "application/json")], body: body),
            let id = decodeId(create.body) else { return "" }
        defer {
            let runtime = self.runtime
            Task { _ = await runtime.proxyRequest(method: "DELETE", path: "/containers/\(id)?force=true", headers: [], body: Data()) }
        }
        guard let start = await runtime.proxyRequest(method: "POST", path: "/containers/\(id)/start", headers: [], body: Data()),
            start.statusCode == 204 || start.isSuccess else { return "" }
        _ = await runtime.proxyRequest(method: "POST", path: "/containers/\(id)/wait", headers: [], body: Data())
        guard let logs = await runtime.proxyRequest(method: "GET", path: "/containers/\(id)/logs?stdout=1&stderr=1", headers: [], body: Data()) else { return "" }
        return DockerLogFrames.plainText(logs.body)
    }

    private func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }

    static func safePath(_ path: String) -> String {
        let cleaned = path.replacingOccurrences(of: "..", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/data/\(cleaned)"
    }

    /// Parse `ls -lA --full-time` output into entries.
    static func parseListing(_ output: String) -> [VolumeEntry] {
        var entries: [VolumeEntry] = []
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9, let mode = columns.first else { continue }
            let isDirectory = mode.hasPrefix("d")
            let isLink = mode.hasPrefix("l")
            let name = columns[8...].joined(separator: " ")
            guard !name.isEmpty, name != "." else { continue }
            let bytes = Int(columns[4]) ?? 0
            entries.append(VolumeEntry(name: name, isDirectory: isDirectory || isLink, size: isDirectory ? "—" : DockerFormat.bytes(Int64(bytes))))
        }
        return entries.sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }
    }
}
