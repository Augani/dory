@testable import DoryHV

/// Direct backend fixtures still enter through the real transport status/feature handshake.
func makeNegotiatedMMIOTestTransport(
    baseAddress: UInt64,
    backend: any VirtioDeviceBackend,
    memory: GuestMemory,
    queueLimits: VirtqueueLimits = .hardenedDefault,
    driverReady: Bool = true,
    interrupt: @escaping () -> Void
) -> VirtioMMIOTransport {
    let transport = VirtioMMIOTransport(baseAddress: baseAddress, backend: backend,
        memory: memory, queueLimits: queueLimits, interrupt: interrupt)
    if driverReady { finishMMIOTestDriverNegotiation(transport) }
    return transport
}
