import Foundation

enum ContainerWait {
    static func statusCode(_ code: Int?) -> Int { code ?? 0 }
}

enum PullProgress {
    struct Line: Encodable {
        var status: String
        var id: String?
    }

    struct ErrorDetail: Encodable {
        var message: String
    }

    struct ErrorLine: Encodable {
        var errorDetail: ErrorDetail
        var error: String
    }

    static func lines(repository: String, tag: String, reference: String) -> [Data] {
        [
            line(status: "Pulling from \(repository)", id: tag),
            line(status: "Status: Downloaded newer image for \(reference)", id: nil),
            line(status: "Pulled \(reference)", id: nil),
        ]
    }

    static func error(message: String) -> Data {
        let fallback = Data(#"{"errorDetail":{"message":"pull failed"},"error":"pull failed"}"#.utf8)
        let encoded = (try? JSONEncoder().encode(ErrorLine(errorDetail: ErrorDetail(message: message), error: message))) ?? fallback
        return encoded + Data("\n".utf8)
    }

    private static func line(status: String, id: String?) -> Data {
        let encoded = (try? JSONEncoder().encode(Line(status: status, id: id))) ?? Data(#"{"status":"pull progress unavailable"}"#.utf8)
        return encoded + Data("\n".utf8)
    }
}

enum PullReference {
    struct Resolved: Equatable {
        var repository: String
        var tag: String
        var reference: String
    }

    static func resolve(fromImage: String, tagQuery: String?) -> Resolved {
        let split = DockerRegistry.splitImageRef(fromImage)
        let requestedTag = tagQuery.flatMap { $0.isEmpty ? nil : $0 }
        let repository = split.repo
        let tag = requestedTag ?? split.tag
        let reference = tag.hasPrefix("sha256:") ? "\(repository)@\(tag)" : "\(repository):\(tag)"
        return Resolved(repository: repository, tag: tag, reference: reference)
    }
}

enum ShimContainerMapping {
    static func summary(
        _ container: Container,
        all: Bool,
        imageID: String? = nil,
        sizeRw: Int64? = nil,
        sizeRootFs: Int64? = nil
    ) -> DockerContainerOut? {
        guard all || container.status == .running else { return nil }
        return DockerContainerOut(
            Id: container.id,
            Names: ["/\(container.name)"],
            Image: container.image,
            ImageID: imageID ?? container.image,
            Command: container.command,
            Created: container.createdEpoch ?? 0,
            State: state(container.status),
            Status: statusText(container),
            Ports: ports(container.ports),
            Labels: container.labels,
            HostConfig: DockerContainerHostConfigSummaryOut(NetworkMode: networkMode(container)),
            NetworkSettings: DockerContainerNetworkSettingsOut(Networks: networkSettings(container)),
            Mounts: mounts(container),
            SizeRw: sizeRw,
            SizeRootFs: sizeRootFs
        )
    }

    static func state(_ status: RunState) -> String {
        switch status {
        case .running: "running"
        case .paused: "paused"
        case .stopped: "exited"
        }
    }

    static func statusText(_ container: Container) -> String {
        switch container.status {
        case .running: "Up \(container.uptime)"
        case .paused: "Paused"
        case .stopped: "Exited"
        }
    }

    static func ports(_ display: String) -> [DockerPortOut] {
        ContainerPortDisplay.mappings(display).map {
            DockerPortOut(PrivatePort: $0.containerPort, PublicPort: $0.hostPort, portType: $0.proto)
        }
    }

    static func networkMode(_ container: Container) -> String {
        container.networkMode ?? container.networks.first ?? "default"
    }

    static func networkSettings(_ container: Container) -> [String: DockerEndpointSettings] {
        Dictionary(uniqueKeysWithValues: container.networks.map { network in
            var endpoint = container.networkEndpointSettings[network] ?? DockerEndpointSettings()
            if endpoint.IPAddress?.isEmpty != false, container.ipAddress != "—" {
                endpoint.IPAddress = container.ipAddress
            }
            return (network, endpoint)
        })
    }

    static func mounts(_ container: Container) -> [DockerInspectMountOut] {
        let legacyBinds = container.volumes.compactMap(DockerInspectMountOut.legacyBind)
        let modernMounts = container.mounts.compactMap(DockerInspectMountOut.mount)
        let targets = unique(container.volumeTargets + container.volumes.filter { !DockerCreateBody.isLegacyBind($0) })
            .map(DockerInspectMountOut.volumeTarget)
        return legacyBinds + modernMounts + targets
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum DockerListFilters {
    static func parse(_ raw: String?) -> [String: [String]] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var filters: [String: [String]] = [:]
        for (key, value) in object {
            if let values = value as? [String] {
                filters[key] = values
            } else if let values = value as? [Any] {
                filters[key] = values.map(String.init(describing:))
            } else if let values = value as? [String: Any] {
                filters[key] = values.compactMap { selector, enabled in
                    if let bool = enabled as? Bool { return bool ? selector : nil }
                    if let number = enabled as? NSNumber { return number.boolValue ? selector : nil }
                    return selector
                }
            } else {
                filters[key] = [String(describing: value)]
            }
        }
        return filters
    }

    static func matches(_ container: Container, filters: [String: [String]]) -> Bool {
        matches(container, filters: filters, containers: [])
    }

    static func matches(_ container: Container, filters: [String: [String]], containers: [Container]) -> Bool {
        for (key, values) in filters where !values.isEmpty {
            switch key {
            case "id":
                guard values.contains(where: { container.id.hasPrefix($0) }) else { return false }
            case "name":
                guard values.contains(where: { container.name.localizedCaseInsensitiveContains($0) }) else { return false }
            case "status":
                guard values.contains(statusValue(container.status)) else { return false }
            case "exited":
                guard let exitCode = container.exitCode,
                      values.contains(String(exitCode)) else { return false }
            case "health":
                guard values.contains(healthValue(container)) else { return false }
            case "label":
                guard values.allSatisfy({ matchesLabel($0, labels: container.labels) }) else { return false }
            case "ancestor":
                guard values.contains(where: { container.image == $0 || container.image.hasPrefix("\($0):") }) else { return false }
            case "volume":
                guard values.contains(where: { matchesVolume($0, container: container) }) else { return false }
            case "network":
                guard values.contains(where: { matchesNetwork($0, container: container) }) else { return false }
            case "publish":
                guard values.contains(where: { matchesPort($0, container: container, publishedOnly: true) }) else { return false }
            case "expose":
                guard values.contains(where: { matchesPort($0, container: container, publishedOnly: false) }) else { return false }
            case "before":
                guard let created = container.createdEpoch,
                      values.contains(where: {
                          guard let reference = containerCreatedEpoch(matching: $0, in: containers) else { return false }
                          return created < reference
                      }) else { return false }
            case "since":
                guard let created = container.createdEpoch,
                      values.contains(where: {
                          guard let reference = containerCreatedEpoch(matching: $0, in: containers) else { return false }
                          return created > reference
                      }) else { return false }
            default:
                continue
            }
        }
        return true
    }

    static func matches(_ image: DockerImage, filters: [String: [String]]) -> Bool {
        matches(image, filters: filters, images: [])
    }

    static func matches(_ image: DockerImage, filters: [String: [String]], images: [DockerImage]) -> Bool {
        for (key, values) in filters where !values.isEmpty {
            switch key {
            case "reference":
                guard values.contains(where: { matchesReference($0, image: image) }) else { return false }
            case "label":
                guard values.allSatisfy({ matchesLabel($0, labels: image.labels) }) else { return false }
            case "dangling":
                guard values.contains(where: { danglingValue($0) == isDangling(image) }) else { return false }
            case "before":
                guard values.contains(where: { image.createdEpoch < (imageCreatedEpoch(matching: $0, in: images) ?? Int.min) }) else { return false }
            case "since":
                guard values.contains(where: { image.createdEpoch > (imageCreatedEpoch(matching: $0, in: images) ?? Int.max) }) else { return false }
            default:
                continue
            }
        }
        return true
    }

    static func matches(_ volume: Volume, filters: [String: [String]]) -> Bool {
        for (key, values) in filters where !values.isEmpty {
            switch key {
            case "name":
                guard values.contains(where: { volume.name.localizedCaseInsensitiveContains($0) }) else { return false }
            case "driver":
                guard values.contains(volume.driver) else { return false }
            case "dangling":
                guard values.contains(where: { danglingValue($0) == isDangling(volume) }) else { return false }
            case "label":
                guard values.allSatisfy({ matchesLabel($0, labels: volume.labels) }) else { return false }
            default:
                continue
            }
        }
        return true
    }

    static func matches(_ network: DoryNetwork, filters: [String: [String]]) -> Bool {
        for (key, values) in filters where !values.isEmpty {
            switch key {
            case "id":
                guard values.contains(where: { network.name.hasPrefix($0) }) else { return false }
            case "name":
                guard values.contains(where: { network.name.localizedCaseInsensitiveContains($0) }) else { return false }
            case "driver":
                guard values.contains(network.driver) else { return false }
            case "scope":
                guard values.contains(network.scope) else { return false }
            case "type":
                guard values.contains(networkType(network)) else { return false }
            case "label":
                guard values.allSatisfy({ matchesLabel($0, labels: network.labels) }) else { return false }
            default:
                continue
            }
        }
        return true
    }

    private static func statusValue(_ status: RunState) -> String {
        switch status {
        case .running: "running"
        case .paused: "paused"
        case .stopped: "exited"
        }
    }

    private static func healthValue(_ container: Container) -> String {
        container.health?.rawValue ?? "none"
    }

    private static func matchesLabel(_ selector: String, labels: [String: String]) -> Bool {
        guard let eq = selector.firstIndex(of: "=") else { return labels[selector] != nil }
        let key = String(selector[selector.startIndex..<eq])
        let value = String(selector[selector.index(after: eq)...])
        return labels[key] == value
    }

    private static func matchesReference(_ selector: String, image: DockerImage) -> Bool {
        guard !selector.isEmpty else { return false }
        let reference = imageReference(image)
        let digest = image.imageID.hasPrefix("sha256:") ? image.imageID : "sha256:\(image.imageID)"
        return reference == selector
            || image.repository == selector
            || image.imageID == selector
            || digest == selector
            || image.imageID.hasPrefix(selector.replacingOccurrences(of: "sha256:", with: ""))
            || globMatches(selector, reference)
    }

    private static func matchesContainerReference(_ selector: String, container: Container) -> Bool {
        guard !selector.isEmpty else { return false }
        let name = selector.hasPrefix("/") ? String(selector.dropFirst()) : selector
        return container.id == selector
            || container.id.hasPrefix(selector)
            || container.name == name
            || "/\(container.name)" == selector
    }

    private static func matchesVolume(_ selector: String, container: Container) -> Bool {
        guard !selector.isEmpty else { return false }
        let declaredVolumes = container.volumes + container.volumeTargets
        if declaredVolumes.contains(where: { volume in
            volume == selector
                || volume.hasPrefix("\(selector):")
                || legacyVolumeFields(volume).contains(selector)
        }) {
            return true
        }
        return container.mounts.contains { mount in
            mount.source == selector || mount.target == selector
        }
    }

    private static func matchesNetwork(_ selector: String, container: Container) -> Bool {
        guard !selector.isEmpty else { return false }
        return container.networks.contains { $0 == selector || $0.localizedCaseInsensitiveContains(selector) }
    }

    private static func matchesPort(_ selector: String, container: Container, publishedOnly: Bool) -> Bool {
        guard let filter = PortFilter(selector) else { return false }
        return ContainerPortDisplay.mappings(container.ports).contains { mapping in
            guard !publishedOnly || mapping.hostPort != nil else { return false }
            guard mapping.proto == filter.proto else { return false }
            return filter.range.contains(mapping.containerPort)
        }
    }

    private struct PortFilter {
        var range: ClosedRange<Int>
        var proto: String

        init?(_ raw: String) {
            let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
            guard let portPart = parts.first, !portPart.isEmpty else { return nil }
            proto = parts.count > 1 && !parts[1].isEmpty ? parts[1].lowercased() : "tcp"
            let bounds = portPart.split(separator: "-", maxSplits: 1).map(String.init)
            guard let lower = bounds.first.flatMap(Int.init) else { return nil }
            let upper = bounds.count > 1 ? (Int(bounds[1]) ?? lower) : lower
            range = min(lower, upper)...max(lower, upper)
        }
    }

    private static func legacyVolumeFields(_ volume: String) -> [String] {
        let parts = volume.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return [volume] }
        return [parts[0], parts[1]]
    }

    private static func imageReference(_ image: DockerImage) -> String {
        image.tag.isEmpty ? image.repository : "\(image.repository):\(image.tag)"
    }

    private static func isDangling(_ image: DockerImage) -> Bool {
        image.repository == "<none>" || image.tag == "<none>" || image.repository.isEmpty || image.tag.isEmpty
    }

    private static func isDangling(_ volume: Volume) -> Bool {
        volume.usedBy == "—" || volume.usedBy.isEmpty
    }

    private static func networkType(_ network: DoryNetwork) -> String {
        ["bridge", "host", "none"].contains(network.name) ? "builtin" : "custom"
    }

    private static func imageCreatedEpoch(matching selector: String, in images: [DockerImage]) -> Int? {
        images.first(where: { matchesReference(selector, image: $0) })?.createdEpoch
    }

    private static func containerCreatedEpoch(matching selector: String, in containers: [Container]) -> Int? {
        containers.first(where: { matchesContainerReference(selector, container: $0) })?.createdEpoch
    }

    private static func danglingValue(_ value: String) -> Bool {
        ["1", "true", "yes"].contains(value.lowercased())
    }

    private static func globMatches(_ pattern: String, _ value: String) -> Bool {
        guard pattern.contains("*") || pattern.contains("?") else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}
