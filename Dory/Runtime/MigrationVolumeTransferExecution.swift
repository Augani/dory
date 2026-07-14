import Foundation

struct MigrationHelperContainerInspection: Decodable {
    let state: MigrationHelperContainerState

    enum CodingKeys: String, CodingKey { case state = "State" }
}

struct MigrationHelperContainerState: Decodable {
    let status: String?
    let running: Bool?
    let exitCode: Int?
    let error: String?
    let oomKilled: Bool?

    enum CodingKeys: String, CodingKey {
        case status = "Status"
        case running = "Running"
        case exitCode = "ExitCode"
        case error = "Error"
        case oomKilled = "OOMKilled"
    }
}

struct MigrationVolumeHelperDefinition {
    enum Side { case source, target }

    let side: Side
    let role: String
    let image: String
    let volume: String
    let readOnly: Bool
    let command: [String]
}

struct MigrationVolumeScannedManifest {
    let containerID: String
    let archive: Data
    let bytes: Data
    let manifest: MigrationVolumeManifest
}

struct MigrationVolumeTransferArtifacts {
    var sourceContainers: [String] = []
    var targetContainers: [String] = []
    var sourceInstallation: MigrationTransferHelperInstallation?
    var targetInstallation: MigrationTransferHelperInstallation?
}

struct MigrationVolumeTransferExecution {
    let helperAsset: MigrationTransferHelperAsset
    let request: MigrationVolumeTransferRequest
    let source: any ContainerRuntime
    let target: any ContainerRuntime
    var artifacts = MigrationVolumeTransferArtifacts()

    mutating func execute() async throws -> MigrationVolumeTransferReceipt {
        let images = try await installHelpers()
        let initial = try await scanInitialSource(image: images.source)
        try await transferAndRepair(initial: initial, targetImage: images.target)
        try await verifySourceUnchanged(initial: initial, image: images.source)
        let verifiedTarget = try await scanVerifiedTarget(image: images.target)
        guard verifiedTarget.manifest == initial.manifest.normalizedTarget,
              initial.manifest.socketCount > 0 || verifiedTarget.bytes == initial.bytes else {
            throw MigrationVolumeTransferError.targetMismatch
        }
        return receipt(source: initial, target: verifiedTarget)
    }

    mutating func verify() async throws -> MigrationVolumeTransferReceipt {
        let images = try await installHelpers()
        let initial = try await scanInitialSource(image: images.source)
        let verifiedTarget = try await scanVerifiedTarget(image: images.target)
        try await verifySourceUnchanged(initial: initial, image: images.source)
        guard verifiedTarget.manifest == initial.manifest.normalizedTarget,
              initial.manifest.socketCount > 0 || verifiedTarget.bytes == initial.bytes else {
            throw MigrationVolumeTransferError.targetMismatch
        }
        return receipt(source: initial, target: verifiedTarget)
    }

    mutating func installHelpers() async throws -> (source: String, target: String) {
        artifacts.sourceInstallation = try await helperAsset.install(
            on: source,
            operationID: request.operationID
        )
        artifacts.targetInstallation = try await helperAsset.install(
            on: target,
            operationID: request.operationID
        )
        guard let sourceImage = artifacts.sourceInstallation?.imageID,
              let targetImage = artifacts.targetInstallation?.imageID else {
            throw MigrationVolumeTransferError.helper("helper installation disappeared")
        }
        return (sourceImage, targetImage)
    }

    mutating func scanInitialSource(image: String) async throws -> MigrationVolumeScannedManifest {
        try await scan(
            MigrationVolumeHelperDefinition(
                side: .source,
                role: "source-scan",
                image: image,
                volume: request.sourceVolume,
                readOnly: true,
                command: ["scan", "--root", "/data", "--output", "/manifest.json"]
            ),
            runtime: source,
            displayRole: "source scan"
        )
    }

    mutating func transferAndRepair(
        initial: MigrationVolumeScannedManifest,
        targetImage: String
    ) async throws {
        let carrier = try await createHelper(MigrationVolumeHelperDefinition(
            side: .target,
            role: "target-carrier",
            image: targetImage,
            volume: request.targetVolume,
            readOnly: false,
            command: ["scan", "--root", "/data", "--output", "/unused.json"]
        ), runtime: target)
        try await target.copyInThrowing(
            containerID: carrier,
            path: "/data",
            archiveStream: source.copyOutStream(containerID: initial.containerID, path: "/data/.")
        )
        let repairer = try await createHelper(MigrationVolumeHelperDefinition(
            side: .target,
            role: "target-repair",
            image: targetImage,
            volume: request.targetVolume,
            readOnly: false,
            command: ["repair", "--root", "/data", "--manifest", "/manifest.json"]
        ), runtime: target)
        try await target.copyInThrowing(
            containerID: repairer,
            path: "/",
            archiveStream: Self.oneChunkStream(initial.archive)
        )
        try await runHelper(repairer, role: "target repair", on: target)
    }

    mutating func verifySourceUnchanged(
        initial: MigrationVolumeScannedManifest,
        image: String
    ) async throws {
        let rescanned = try await scan(
            MigrationVolumeHelperDefinition(
                side: .source,
                role: "source-rescan",
                image: image,
                volume: request.sourceVolume,
                readOnly: true,
                command: ["scan", "--root", "/data", "--output", "/manifest.json"]
            ),
            runtime: source,
            displayRole: "source rescan"
        )
        guard rescanned.bytes == initial.bytes else {
            throw MigrationVolumeTransferError.sourceDrift
        }
    }

    mutating func scanVerifiedTarget(image: String) async throws -> MigrationVolumeScannedManifest {
        try await scan(
            MigrationVolumeHelperDefinition(
                side: .target,
                role: "target-scan",
                image: image,
                volume: request.targetVolume,
                readOnly: true,
                command: ["scan", "--root", "/data", "--output", "/manifest.json"]
            ),
            runtime: target,
            displayRole: "target scan"
        )
    }

    func receipt(
        source: MigrationVolumeScannedManifest,
        target: MigrationVolumeScannedManifest
    ) -> MigrationVolumeTransferReceipt {
        MigrationVolumeTransferReceipt(
            sourceManifest: source.bytes,
            targetManifest: target.bytes,
            sourceManifestSha256: MigrationTransferHelperAsset.sha256(source.bytes),
            targetManifestSha256: MigrationTransferHelperAsset.sha256(target.bytes),
            sourceEntryCount: source.manifest.entries.count,
            verifiedTargetEntryCount: target.manifest.entries.count,
            excludedSocketCount: source.manifest.socketCount,
            containsDeviceNodes: source.manifest.containsDeviceNodes
        )
    }

    mutating func scan(
        _ definition: MigrationVolumeHelperDefinition,
        runtime: any ContainerRuntime,
        displayRole: String
    ) async throws -> MigrationVolumeScannedManifest {
        let containerID = try await createHelper(definition, runtime: runtime)
        try await runHelper(containerID, role: displayRole, on: runtime)
        let archive = try await boundedArchive(
            from: runtime,
            containerID: containerID,
            path: "/manifest.json"
        )
        let bytes = try MigrationTarArchive.extractSingleRegularFile(
            named: "manifest.json",
            from: archive
        )
        return MigrationVolumeScannedManifest(
            containerID: containerID,
            archive: archive,
            bytes: bytes,
            manifest: try MigrationVolumeManifest.decodeAndValidate(bytes)
        )
    }
}

extension MigrationVolumeTransferExecution {
    mutating func createHelper(
        _ definition: MigrationVolumeHelperDefinition,
        runtime: any ContainerRuntime
    ) async throws -> String {
        let identity = MigrationTransferHelperAsset.sha256(Data(definition.volume.utf8))
        let operation = request.operationID.uuidString.lowercased()
        let name = "dory-op-\(operation.prefix(12))-\(identity.prefix(12))-\(definition.role)"
        var spec = ContainerSpec(name: name, image: definition.image, platform: "linux/arm64")
        spec.command = definition.command
        spec.networkMode = "none"
        spec.networkDisabled = true
        spec.mounts = [ContainerMount(
            type: "volume",
            source: definition.volume,
            target: "/data",
            readOnly: definition.readOnly,
            volumeOptions: DockerVolumeOptions(NoCopy: true)
        )]
        spec.labels = ownershipLabels(role: definition.role)
        do {
            let id = try await runtime.create(spec)
            switch definition.side {
            case .source: artifacts.sourceContainers.append(id)
            case .target: artifacts.targetContainers.append(id)
            }
            return id
        } catch {
            throw MigrationVolumeTransferError.helper("create \(definition.role): \(error)")
        }
    }

    func ownershipLabels(role: String) -> [String: String] {
        [
            "dev.dory.operation.id": request.operationID.uuidString.lowercased(),
            "dev.dory.source.authority": request.sourceAuthorityHash,
            "dev.dory.object.kind": "volume-transfer-helper",
            "dev.dory.original.identity": request.sourceVolume,
            "dev.dory.target.identity": request.targetVolume,
            "dev.dory.operation.state": "staging",
            "dev.dory.operation.role": role
        ]
    }

    func runHelper(
        _ containerID: String,
        role: String,
        on runtime: any ContainerRuntime
    ) async throws {
        do {
            try await runtime.start(containerID: containerID)
        } catch {
            throw MigrationVolumeTransferError.helper("start \(role): \(error)")
        }
        while true {
            try Task.checkCancellation()
            let state = try await inspectHelper(containerID, role: role, on: runtime)
            if state.running == true {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }
            guard state.status == "exited", state.exitCode == 0,
                  state.oomKilled != true, state.error?.isEmpty ?? true else {
                let detail = state.error?.isEmpty == false
                    ? state.error ?? "unknown engine error"
                    : "status \(state.status ?? "unknown"), exit \(state.exitCode ?? -1)"
                throw MigrationVolumeTransferError.helper("\(role): \(detail)")
            }
            return
        }
    }

    func inspectHelper(
        _ containerID: String,
        role: String,
        on runtime: any ContainerRuntime
    ) async throws -> MigrationHelperContainerState {
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/containers/\(DockerImageOps.pathComponent(containerID))/json",
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ), response.isSuccess,
              let inspection = try? JSONDecoder().decode(
                  MigrationHelperContainerInspection.self,
                  from: response.body
              ), inspection.state.running != nil else {
            throw MigrationVolumeTransferError.helper("inspect \(role)")
        }
        return inspection.state
    }

    func boundedArchive(
        from runtime: any ContainerRuntime,
        containerID: String,
        path: String
    ) async throws -> Data {
        var archive = Data()
        do {
            for try await chunk in runtime.copyOutStream(containerID: containerID, path: path) {
                guard !chunk.isEmpty,
                      archive.count <= MigrationTarArchive.maximumManifestArchiveBytes - chunk.count else {
                    throw MigrationVolumeTransferError.helper("manifest archive exceeded its limit")
                }
                archive.append(chunk)
            }
        } catch {
            throw MigrationVolumeTransferError.helper("read verification manifest: \(error)")
        }
        guard !archive.isEmpty else {
            throw MigrationVolumeTransferError.helper("verification manifest archive is empty")
        }
        return archive
    }

    static func oneChunkStream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        }
    }

    mutating func cleanup() async -> [String] {
        var failures: [String] = []
        failures += await removeContainers(
            artifacts.targetContainers,
            from: target,
            side: "target"
        )
        failures += await removeContainers(
            artifacts.sourceContainers,
            from: source,
            side: "source"
        )
        if let installation = artifacts.targetInstallation {
            do {
                try await helperAsset.removeInstallation(installation, from: target)
            } catch {
                failures.append("remove target helper image tag: \(error)")
            }
        }
        if let installation = artifacts.sourceInstallation {
            do {
                try await helperAsset.removeInstallation(installation, from: source)
            } catch {
                failures.append("remove source helper image tag: \(error)")
            }
        }
        return failures
    }

    func removeContainers(
        _ containers: [String],
        from runtime: any ContainerRuntime,
        side: String
    ) async -> [String] {
        var failures: [String] = []
        for id in containers.reversed() {
            do {
                try await runtime.remove(containerID: id)
            } catch {
                failures.append("remove \(side) helper \(id): \(error)")
            }
        }
        return failures
    }
}
