import Foundation

enum MigrationContainerInspectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(String)
    case invalid(String)
    case unsupported(String)

    var description: String {
        switch self {
        case let .unavailable(name): "cannot inspect source container \(name)"
        case let .invalid(name): "source container \(name) has an incomplete Docker create contract"
        case let .unsupported(detail): detail
        }
    }
}

enum MigrationContainerInspector {
    static func inspect(
        _ container: Container,
        on runtime: any ContainerRuntime,
        sharedHome: String,
        validatePortability: Bool = true
    ) async throws -> ContainerSpec {
        let root = try await inspectedObject(container, runtime: runtime)
        guard var config = root["Config"] as? [String: Any],
              var hostConfig = root["HostConfig"] as? [String: Any],
              let networkSettings = root["NetworkSettings"] as? [String: Any],
              let networks = networkSettings["Networks"] as? [String: Any] else {
            throw MigrationContainerInspectionError.invalid(container.name)
        }
        try resolveMounts(root: root, hostConfig: &hostConfig, containerName: container.name)
        config["HostConfig"] = hostConfig
        config["NetworkingConfig"] = ["EndpointsConfig": networks]
        guard JSONSerialization.isValidJSONObject(config),
              let requestData = try? JSONSerialization.data(withJSONObject: config),
              let request = try? JSONDecoder().decode(DockerCreateRequest.self, from: requestData) else {
            throw MigrationContainerInspectionError.invalid(container.name)
        }
        var specification = request.spec(name: container.name)
        // Docker daemons may report the disabled OOM-killer override as either
        // omitted or false. Both mean the default (OOM killing remains enabled).
        if specification.resources.oomKillDisable == false {
            specification.resources.oomKillDisable = nil
        }
        specification.networks.removeAll { MigrationOperationPlanBuilder.defaultNetworks.contains($0) }
        specification.networkEndpointSettings = portableEndpoints(
            specification.networkEndpointSettings
        )
        if validatePortability {
            try validatePortable(specification, containerName: container.name, sharedHome: sharedHome)
        }
        return specification
    }
}

private extension MigrationContainerInspector {
    struct LegacyMountNormalization {
        let binds: [String]
        let volumes: [[String: Any]]
        let volumeTargets: Set<String>
    }

    static func inspectedObject(
        _ container: Container,
        runtime: any ContainerRuntime
    ) async throws -> [String: Any] {
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/containers/\(DockerImageOps.pathComponent(container.id))/json",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ), response.isSuccess else {
            throw MigrationContainerInspectionError.unavailable(container.name)
        }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw MigrationContainerInspectionError.invalid(container.name)
        }
        return root
    }

    static func resolveMounts(
        root: [String: Any],
        hostConfig: inout [String: Any],
        containerName: String
    ) throws {
        let mounts = try objectArray(root["Mounts"], containerName: containerName)
        guard !mounts.isEmpty else { return }
        let configured = try objectArray(hostConfig["Mounts"], containerName: containerName)
        let declarations = try stringArray(hostConfig["Binds"], containerName: containerName)
        var resolvedByTarget: [String: [String: Any]] = [:]
        for mount in mounts {
            guard let target = (mount["Target"] ?? mount["Destination"]) as? String,
                  !target.isEmpty,
                  resolvedByTarget.updateValue(mount, forKey: target) == nil else {
                throw MigrationContainerInspectionError.invalid(containerName)
            }
        }
        let resolvedConfigured = configured.map {
            resolveAnonymousVolume($0, from: resolvedByTarget)
        }
        let configuredTargets = Set(configured.compactMap {
            ($0["Target"] ?? $0["Destination"]) as? String
        })
        let tmpfsTargets = Set((hostConfig["Tmpfs"] as? [String: Any] ?? [:]).keys)
        let legacy = try normalizeLegacyVolumes(
            declarations,
            resolvedByTarget: resolvedByTarget,
            containerName: containerName
        )
        if legacy.binds.isEmpty {
            hostConfig.removeValue(forKey: "Binds")
        } else {
            hostConfig["Binds"] = legacy.binds
        }
        let bindTargets = Set(legacy.binds.compactMap(legacyBindTarget))
        let claimedTargets = configuredTargets
            .union(tmpfsTargets)
            .union(bindTargets)
            .union(legacy.volumeTargets)
        hostConfig["Mounts"] = resolvedConfigured + legacy.volumes + mounts.filter { mount in
            guard let target = (mount["Target"] ?? mount["Destination"]) as? String else {
                return true
            }
            return !claimedTargets.contains(target)
        }
    }

    static func objectArray(
        _ value: Any?,
        containerName: String
    ) throws -> [[String: Any]] {
        guard let value, !(value is NSNull) else { return [] }
        guard let result = value as? [[String: Any]] else {
            throw MigrationContainerInspectionError.invalid(containerName)
        }
        return result
    }

    static func stringArray(
        _ value: Any?,
        containerName: String
    ) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let result = value as? [String] else {
            throw MigrationContainerInspectionError.invalid(containerName)
        }
        return result
    }

    static func normalizeLegacyVolumes(
        _ declarations: [String],
        resolvedByTarget: [String: [String: Any]],
        containerName: String
    ) throws -> LegacyMountNormalization {
        var binds: [String] = []
        var volumes: [[String: Any]] = []
        var volumeTargets = Set<String>()
        for declaration in declarations {
            guard let target = legacyBindTarget(declaration),
                  let resolved = resolvedByTarget[target],
                  ((resolved["Type"] as? String) ?? "").lowercased() == "volume" else {
                binds.append(declaration)
                continue
            }
            guard volumeTargets.insert(target).inserted else {
                throw MigrationContainerInspectionError.invalid(containerName)
            }
            volumes.append(try normalizedLegacyVolume(
                declaration,
                resolved: resolved,
                target: target,
                containerName: containerName
            ))
        }
        return LegacyMountNormalization(
            binds: binds,
            volumes: volumes,
            volumeTargets: volumeTargets
        )
    }

    static func normalizedLegacyVolume(
        _ declaration: String,
        resolved: [String: Any],
        target: String,
        containerName: String
    ) throws -> [String: Any] {
        guard let name = (resolved["Name"] as? String), !name.isEmpty else {
            throw MigrationContainerInspectionError.invalid(containerName)
        }
        let modes = legacyModes(declaration)
        let supported: Set<String> = ["ro", "rw", "nocopy"]
        guard modes.isSubset(of: supported),
              !(modes.contains("ro") && modes.contains("rw")) else {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) uses unsupported named-volume modes in \(declaration)"
            )
        }
        var result = resolved
        result["Type"] = "volume"
        result["Name"] = name
        result["Source"] = name
        result["Target"] = target
        if modes.contains("ro") { result["ReadOnly"] = true }
        if modes.contains("rw") { result["ReadOnly"] = false }
        if modes.contains("nocopy") {
            var options = result["VolumeOptions"] as? [String: Any] ?? [:]
            options["NoCopy"] = true
            result["VolumeOptions"] = options
        }
        return result
    }

    static func resolveAnonymousVolume(
        _ configured: [String: Any],
        from resolvedByTarget: [String: [String: Any]]
    ) -> [String: Any] {
        var result = configured
        guard (result["Type"] as? String)?.lowercased() == "volume",
              ((result["Source"] as? String) ?? "").isEmpty,
              let target = (result["Target"] ?? result["Destination"]) as? String,
              let resolved = resolvedByTarget[target],
              let source = (resolved["Name"] ?? resolved["Source"]) as? String,
              !source.isEmpty else { return result }
        result["Source"] = source
        return result
    }

    static func portableEndpoints(
        _ endpoints: [String: DockerEndpointSettings]
    ) -> [String: DockerEndpointSettings] {
        Dictionary(uniqueKeysWithValues: endpoints.compactMap { name, endpoint in
            guard !MigrationOperationPlanBuilder.defaultNetworks.contains(name) else { return nil }
            return (name, DockerEndpointSettings(
                IPAMConfig: endpoint.IPAMConfig,
                Links: endpoint.Links,
                Aliases: endpoint.Aliases,
                DriverOpts: endpoint.DriverOpts
            ))
        })
    }

    static func validatePortable(
        _ specification: ContainerSpec,
        containerName: String,
        sharedHome: String
    ) throws {
        let supportedMounts: Set<String> = ["bind", "tmpfs", "volume"]
        if let mount = specification.mounts.first(where: {
            !supportedMounts.contains($0.type.lowercased())
        }) {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) uses unsupported \(mount.type) mount at \(mount.target)"
            )
        }
        if let path = specification.containerIDFile, !path.isEmpty {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) uses source-daemon ContainerIDFile \(path)"
            )
        }
        if !(specification.resources.devices ?? []).isEmpty
            || !(specification.resources.deviceRequests ?? []).isEmpty
            || !(specification.resources.deviceCgroupRules ?? []).isEmpty {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) uses host devices that are not portable into Dory's VM"
            )
        }
        if let runtime = specification.runtimeName?.lowercased(),
           !runtime.isEmpty,
           !["runc", "crun"].contains(runtime) {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) requires unbundled runtime \(runtime)"
            )
        }
        for mount in specification.mounts where mount.type.lowercased() == "bind" {
            try validateBind(
                source: mount.source,
                target: mount.target,
                containerName: containerName,
                sharedHome: sharedHome
            )
        }
        for declaration in specification.volumes where DockerCreateBody.isLegacyBind(declaration) {
            try validateBind(
                source: legacyBindSource(declaration),
                target: legacyBindTarget(declaration) ?? "?",
                containerName: containerName,
                sharedHome: sharedHome
            )
        }
    }

    static func validateBind(
        source: String?,
        target: String,
        containerName: String,
        sharedHome: String
    ) throws {
        guard let source, !source.isEmpty else {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) bind mount at \(target) has no source path"
            )
        }
        let root = URL(fileURLWithPath: sharedHome).standardizedFileURL.resolvingSymlinksInPath().path
        let url = URL(fileURLWithPath: source).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) bind source \(source) is outside Dory's shared home"
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MigrationContainerInspectionError.unsupported(
                "container \(containerName) bind source \(source) does not exist"
            )
        }
    }

    nonisolated static func legacyBindSource(_ declaration: String) -> String? {
        let pieces = declaration.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard pieces.count >= 2 else { return nil }
        let targetIndex = legacyTargetIndex(pieces)
        guard targetIndex > 0 else { return nil }
        return pieces[..<targetIndex].joined(separator: ":")
    }

    nonisolated static func legacyBindTarget(_ declaration: String) -> String? {
        let pieces = declaration.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard pieces.count >= 2 else { return nil }
        return pieces[legacyTargetIndex(pieces)]
    }

    nonisolated static func legacyTargetIndex(_ pieces: [String]) -> Int {
        let modes: Set<String> = [
            "ro", "rw", "z", "Z", "cached", "delegated", "consistent", "nocopy",
            "private", "rprivate", "shared", "rshared", "slave", "rslave", "bind", "volume"
        ]
        let options = Set(pieces.last?.split(separator: ",").map(String.init) ?? [])
        return pieces.count >= 3 && !options.isDisjoint(with: modes)
            ? pieces.count - 2
            : pieces.count - 1
    }

    nonisolated static func legacyModes(_ declaration: String) -> Set<String> {
        let pieces = declaration.split(
            separator: ":",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard pieces.count >= 3, legacyTargetIndex(pieces) == pieces.count - 2 else { return [] }
        return Set(pieces.last?.split(separator: ",").map(String.init) ?? [])
    }
}
