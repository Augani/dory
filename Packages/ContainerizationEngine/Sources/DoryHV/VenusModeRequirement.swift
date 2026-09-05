/// Converts host renderer discovery failures into an explicit fail-closed GPU configuration error.
/// A caller that asked for Venus must never continue with a VM that has no virtio-gpu device.
public enum VenusModeRequirement {
    public static func require<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch {
            throw VMError.invalidConfiguration(
                "gpu=venus could not attach the host renderer; refusing a headless fallback: \(error)"
            )
        }
    }

    public static func require<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw VMError.invalidConfiguration(
                "gpu=venus could not attach the host renderer; refusing a headless fallback: \(error)"
            )
        }
    }
}
