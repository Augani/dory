import DoryOperations

/// Saved-state suspension serializes backend execution state. The renderer worker's contexts,
/// host-visible mappings, leases, and fence timeline do not yet have a restore protocol, so an
/// accelerated VM must never enter that path partially and discover the incompatibility after the
/// guest or helper has been quiesced.
enum DoryAcceleratedSavedStatePolicy {
    static let rejectionMessage = "Saved-state suspend is unavailable while 3D acceleration is active. Use a cold snapshot, or suspend the guest to RAM instead."

    static func validate(
        graphics: DoryGraphicsAccelerationLevel?,
        unresolvedDesktopPreference: DoryDesktopGraphicsPreference? = nil
    ) throws {
        let usesAcceleratedRenderer = graphics == .hardwareAccelerated3D
            || (graphics == nil && (
                unresolvedDesktopPreference == .automatic
                    || unresolvedDesktopPreference == .virglVenus
            ))
        guard !usesAcceleratedRenderer else {
            throw MachineManagerError.persistence(rejectionMessage)
        }
    }
}
