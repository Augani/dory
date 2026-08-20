import DoryOperations

// Keep the contract available through DoryCore for helper clients that already import it, while
// the canonical definitions live in DoryOperations so the app UI and the daemon use identical
// values without making the app link the FFI-backed core module.
public typealias DoryDesktopVMMPreference = DoryOperations.DoryDesktopVMMPreference
public typealias DoryDesktopGraphicsPreference = DoryOperations.DoryDesktopGraphicsPreference
public typealias DoryDesktopGraphicsBackend = DoryOperations.DoryDesktopGraphicsBackend
public typealias DoryDesktopRuntimeContractError = DoryOperations.DoryDesktopRuntimeContractError
