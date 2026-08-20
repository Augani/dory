@testable import DorydKit
import DoryOperations
import XCTest

final class MachineBackendTests: XCTestCase {
    func testConcreteDescriptorsDescribeOnlyCurrentLinuxMechanisms() {
        let raw = RawHVLinuxMachineBackend.backendDescriptor
        XCTAssertEqual(raw.identity, .doryHypervisor)
        XCTAssertEqual(raw.guestFamilies, [.linux])
        XCTAssertEqual(raw.guestArchitectures, [.arm64])
        XCTAssertEqual(raw.bootMediaKinds, [.installedLinuxBootBundle])
        XCTAssertEqual(raw.lifecycle, .currentMachineManager)

        let vz = VirtualizationFrameworkLinuxMachineBackend.backendDescriptor
        XCTAssertEqual(vz.identity, .appleVirtualizationFramework)
        XCTAssertEqual(vz.guestFamilies, [.linux])
        XCTAssertEqual(vz.guestArchitectures, [.arm64])
        XCTAssertEqual(vz.bootMediaKinds, [.installerISO, .virtualDisk])
        XCTAssertFalse(vz.lifecycle.pause)
        XCTAssertFalse(vz.lifecycle.resume)
    }

    func testProbeFailsClosedForMissingAndUnavailableComponents() {
        let operations = recordingOperations().operations
        let missing = RawHVLinuxMachineBackend(
            executablePath: nil,
            operations: operations,
            executableIsAvailable: { _ in true }
        ).probe()
        XCTAssertEqual(missing.state, .unavailable)
        XCTAssertEqual(missing.failure?.code, .componentNotConfigured)

        let unavailable = VirtualizationFrameworkLinuxMachineBackend(
            executablePath: "/fixture/dory-vmm",
            operations: operations,
            executableIsAvailable: { _ in false }
        ).probe()
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.failure?.code, .componentUnavailable)

        let available = RawHVLinuxMachineBackend(
            executablePath: "/fixture/dory-hv",
            operations: operations,
            executableIsAvailable: { $0 == "/fixture/dory-hv" }
        ).probe()
        XCTAssertTrue(available.isAvailable)
        XCTAssertNil(available.failure)
    }

    func testRegistryRejectsDuplicateBackendIdentity() {
        let operations = recordingOperations().operations
        let first = availableRawBackend(operations: operations)
        let second = availableRawBackend(operations: operations)

        XCTAssertThrowsError(try BackendRegistry(backends: [first, second])) { error in
            let failure = error as? MachineBackendFailure
            XCTAssertEqual(failure?.code, .duplicateRegistration)
            XCTAssertEqual(failure?.backend, .doryHypervisor)
        }
    }

    func testRegistryProbeOrderIsStableAcrossRegistrationOrder() throws {
        let operations = recordingOperations().operations
        let raw = availableRawBackend(operations: operations)
        let vz = availableVZBackend(operations: operations)

        let forward = try BackendRegistry(backends: [raw, vz]).probeAll()
        let reverse = try BackendRegistry(backends: [vz, raw]).probeAll()
        let expected: [DoryVirtualizationBackendIdentity] = [
            .appleVirtualizationFramework,
            .doryHypervisor,
        ]
        XCTAssertEqual(forward.map(\.descriptor.identity), expected)
        XCTAssertEqual(reverse.map(\.descriptor.identity), expected)
    }

    func testRegistryPlansAndDispatchesRawHVLifecycleWithoutChangingOperations() throws {
        let recorder = recordingOperations()
        let registry = try BackendRegistry(backends: [
            availableRawBackend(operations: recorder.operations),
        ])
        let request = MachineBackendPlanRequest(
            machine: rawMachine(),
            capabilityPlan: capabilityPlan(
                backend: .doryHypervisor,
                media: .installedLinuxBootBundle
            )
        )

        let result = registry.plan(request)
        let plan = try XCTUnwrap(result.plan)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(plan.backend.identity, .doryHypervisor)
        XCTAssertEqual(plan.machine.id, "raw-linux")

        let started = registry.start(plan)
        XCTAssertTrue(started.isSuccess)
        XCTAssertEqual(started.observation?.state, .running)
        XCTAssertEqual(recorder.launchBindings.first?.graphics, .hostAcceleratedDisplay)
        XCTAssertEqual(recorder.launchBindings.first?.devices, .minimumBootable)

        let stopped = registry.stop(MachineBackendRuntimeRequest(
            machineID: plan.machine.id,
            backend: .doryHypervisor
        ))
        XCTAssertTrue(stopped.isSuccess)
        XCTAssertEqual(stopped.observation?.state, .stopped)
        XCTAssertEqual(recorder.events, ["start:raw-linux", "stop:raw-linux"])
    }

    func testRegistryPlansVZInstallerWithPlannerSelection() throws {
        let registry = try BackendRegistry(backends: [
            availableVZBackend(operations: recordingOperations().operations),
        ])
        let result = registry.plan(MachineBackendPlanRequest(
            machine: vzInstallerMachine(),
            capabilityPlan: capabilityPlan(
                backend: .appleVirtualizationFramework,
                media: .installerISO
            )
        ))

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.plan?.backend.identity, .appleVirtualizationFramework)
        XCTAssertEqual(result.plan?.capability.request.bootMedia.kind, .installerISO)
    }

    func testPlanningFailsClosedWhenProductPlannerHasNoSelection() throws {
        let registry = try BackendRegistry(backends: [
            availableRawBackend(operations: recordingOperations().operations),
        ])
        let result = registry.plan(MachineBackendPlanRequest(
            machine: rawMachine(),
            capabilityPlan: DoryVirtualMachineBackendPlanResult(
                selectedDescriptor: nil,
                evaluatedDescriptors: [],
                failure: DoryVirtualMachineBackendPlanningFailure(
                    code: .noCandidate,
                    message: "fixture"
                )
            )
        ))

        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.failure?.code, .capabilityPlanRejected)
    }

    func testPlanningFailsClosedForUnregisteredSelectedBackend() throws {
        let registry = try BackendRegistry(backends: [
            availableRawBackend(operations: recordingOperations().operations),
        ])
        let result = registry.plan(MachineBackendPlanRequest(
            machine: vzInstallerMachine(),
            capabilityPlan: capabilityPlan(
                backend: .appleVirtualizationFramework,
                media: .installerISO
            )
        ))

        XCTAssertEqual(result.failure?.code, .backendNotRegistered)
        XCTAssertEqual(result.failure?.backend, .appleVirtualizationFramework)
    }

    func testAdapterRejectsSelectionMissingFromPlannerEvaluation() {
        let backend = availableRawBackend(operations: recordingOperations().operations)
        let descriptor = capabilityDescriptor(
            backend: .doryHypervisor,
            media: .installedLinuxBootBundle
        )
        let result = backend.plan(MachineBackendPlanRequest(
            machine: rawMachine(),
            capabilityPlan: DoryVirtualMachineBackendPlanResult(
                selectedDescriptor: descriptor,
                evaluatedDescriptors: [],
                failure: nil
            )
        ))

        XCTAssertEqual(result.failure?.code, .capabilitySelectionInvalid)
    }

    func testRawAdapterRejectsConfigurationThatWouldRouteToCompatibilityLauncher() {
        let backend = availableRawBackend(operations: recordingOperations().operations)
        var machine = rawMachine()
        machine.environment[DoryDesktopVMMPreference.environmentKey] = "compatible"
        let result = backend.plan(MachineBackendPlanRequest(
            machine: machine,
            capabilityPlan: capabilityPlan(
                backend: .doryHypervisor,
                media: .installedLinuxBootBundle
            )
        ))

        XCTAssertEqual(result.failure?.code, .machineConfigurationIncompatible)
    }

    func testVZInstallerPlanRequiresAttachedInstallerMedia() {
        let backend = availableVZBackend(operations: recordingOperations().operations)
        var machine = vzInstallerMachine()
        machine.installerISOPath = nil
        let result = backend.plan(MachineBackendPlanRequest(
            machine: machine,
            capabilityPlan: capabilityPlan(
                backend: .appleVirtualizationFramework,
                media: .installerISO
            )
        ))

        XCTAssertEqual(result.failure?.code, .machineConfigurationIncompatible)
    }

    func testPauseAndResumeAreExplicitlyUnsupportedAndDoNotInvokeLauncher() {
        let recorder = recordingOperations()
        let backend = availableRawBackend(operations: recorder.operations)
        let request = MachineBackendRuntimeRequest(
            machineID: "raw-linux",
            backend: .doryHypervisor
        )

        XCTAssertEqual(backend.pause(request).failure?.code, .lifecycleOperationUnsupported)
        XCTAssertEqual(backend.resume(request).failure?.code, .lifecycleOperationUnsupported)
        XCTAssertEqual(recorder.events, [])
    }

    func testBackendPlanRoundTripsWithPlannerCapabilityEvidence() throws {
        let backend = availableVZBackend(operations: recordingOperations().operations)
        let plan = try XCTUnwrap(backend.plan(MachineBackendPlanRequest(
            machine: vzInstallerMachine(),
            capabilityPlan: capabilityPlan(
                backend: .appleVirtualizationFramework,
                media: .installerISO
            )
        )).plan)

        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(MachineBackendPlan.self, from: data), plan)
    }

    private func availableRawBackend(
        operations: MachineBackendCompatibilityOperations
    ) -> RawHVLinuxMachineBackend {
        RawHVLinuxMachineBackend(
            executablePath: "/fixture/dory-hv",
            operations: operations,
            executableIsAvailable: { _ in true }
        )
    }

    private func availableVZBackend(
        operations: MachineBackendCompatibilityOperations
    ) -> VirtualizationFrameworkLinuxMachineBackend {
        VirtualizationFrameworkLinuxMachineBackend(
            executablePath: "/fixture/dory-vmm",
            operations: operations,
            executableIsAvailable: { _ in true }
        )
    }

    private func rawMachine() -> DoryMachineConfiguration {
        DoryMachineConfiguration(
            id: "raw-linux",
            kernelPath: "/fixture/direct-kernel",
            rootfsPath: "/fixture/linux.raw",
            bootMode: .linuxKernel,
            displayMode: .desktop
        )
    }

    private func vzInstallerMachine() -> DoryMachineConfiguration {
        DoryMachineConfiguration(
            id: "vz-linux",
            kernelPath: "/fixture/nvram",
            rootfsPath: "/fixture/linux.raw",
            bootMode: .efi,
            installerISOPath: "/fixture/ubuntu.iso",
            displayMode: .desktop
        )
    }

    private func capabilityPlan(
        backend: DoryVirtualizationBackendIdentity,
        media: DoryBootMediaKind
    ) -> DoryVirtualMachineBackendPlanResult {
        let descriptor = capabilityDescriptor(backend: backend, media: media)
        return DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: descriptor,
            evaluatedDescriptors: [descriptor],
            failure: nil
        )
    }

    private func capabilityDescriptor(
        backend: DoryVirtualizationBackendIdentity,
        media: DoryBootMediaKind
    ) -> DoryVirtualMachineCapabilityDescriptor {
        let request = DoryVirtualMachineCapabilityRequest(
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            bootMedia: DoryBootMedia(kind: media, source: .userProvided),
            backend: backend,
            graphics: .hostAcceleratedDisplay,
            devices: .minimumBootable
        )
        return DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: request,
            availability: DoryCapabilityAvailability(
                supportTier: .supported,
                state: .available
            ),
            resolvedDevices: request.devices
        )
    }

    private func recordingOperations() -> OperationRecorder {
        OperationRecorder()
    }
}

private final class OperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [String] = []
    private var recordedLaunchBindings: [MachineBackendLaunchBinding] = []

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    var launchBindings: [MachineBackendLaunchBinding] {
        lock.withLock { recordedLaunchBindings }
    }

    lazy var operations = MachineBackendCompatibilityOperations(
        authorizedStart: { [weak self] binding in
            self?.append(binding)
            return MachineBackendRuntimeObservation(
                machineID: binding.machineID,
                state: .running,
                processIdentifier: 42
            )
        },
        stop: { [weak self] id in
            self?.append("stop:\(id)")
            return MachineBackendRuntimeObservation(machineID: id, state: .stopped)
        }
    )

    private func append(_ event: String) {
        lock.withLock { recordedEvents.append(event) }
    }

    private func append(_ binding: MachineBackendLaunchBinding) {
        lock.withLock {
            recordedLaunchBindings.append(binding)
            recordedEvents.append("start:\(binding.machineID)")
        }
    }
}
