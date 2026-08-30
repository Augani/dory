import DoryMachineARMVirt

/// Source-compatible name for DoryHV device implementations. The binary writer is owned by the
/// machine-ABI module so firmware and boot-contract tests do not require Hypervisor.framework.
public typealias FDTBuilder = DoryFlattenedDeviceTreeBuilder
