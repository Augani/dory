import Foundation

enum MachineError: Error, Sendable {
    case engineUnavailable
    case imageBuildFailed(String)
    case createFailed(String)
    case notFound(String)
}

enum MachineImageBuilder {
    static func dockerfile(for distro: MachineDistro) -> String {
        switch distro.id {
        case "ubuntu", "debian":
            return """
            FROM \(distro.baseImage)
            ENV DEBIAN_FRONTEND=noninteractive
            RUN apt-get update \\
             && apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session sudo bash ca-certificates iproute2 iputils-ping curl \\
             && rm -rf /var/lib/apt/lists/* \\
             && (systemctl mask systemd-resolved.service systemd-networkd.service || true)
            STOPSIGNAL SIGRTMIN+3
            CMD ["/sbin/init"]
            """
        case "fedora":
            return """
            FROM \(distro.baseImage)
            RUN dnf -y install systemd sudo passwd iproute procps-ng \\
             && dnf clean all \\
             && (systemctl mask systemd-resolved.service || true)
            STOPSIGNAL SIGRTMIN+3
            CMD ["/sbin/init"]
            """
        default:
            return """
            FROM \(distro.baseImage)
            RUN apk add --no-cache bash sudo shadow iproute2 ca-certificates
            CMD ["tail", "-f", "/dev/null"]
            """
        }
    }

    static func ensureImage(_ distro: MachineDistro, runtime: any ContainerRuntime,
                            progress: @escaping @Sendable (String) -> Void) async throws -> String {
        let tag = distro.machineImageTag
        if await runtime.inspectImage(id: tag) != nil { return tag }

        progress("Pulling \(distro.baseImage)…")
        try? await runtime.pull(image: distro.baseImage)

        progress("Building \(distro.display) machine image (one-time)…")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-machine-build-\(distro.id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try dockerfile(for: distro).write(to: dir.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

        guard let tar = AppStore.tarDirectory(dir) else { throw MachineError.imageBuildFailed("Could not package build context") }
        let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tag
        var lastError: String?
        for await chunk in runtime.build(contextTar: tar, query: "t=\(encodedTag)") {
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                guard let text = AppStore.parseBuildLine(Data(line.utf8)) else { continue }
                progress(text)
                if text.hasPrefix("ERROR:") { lastError = text }
            }
        }
        guard await runtime.inspectImage(id: tag) != nil else {
            throw MachineError.imageBuildFailed(lastError ?? "image \(tag) not present after build")
        }
        return tag
    }
}
