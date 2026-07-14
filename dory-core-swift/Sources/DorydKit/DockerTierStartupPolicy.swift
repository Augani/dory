import Foundation

public enum DockerTierStartupPolicy {
    public static func shouldAutostartDockerTier(
        environment: [String: String],
        persistedRuntimeMode: @autoclosure () -> String,
        persistedEngineDesiredState: @autoclosure () -> String
    ) -> Bool {
        if isTruthy(environment["DORYD_FORCE_AUTOSTART_DOCKER_TIER"]) {
            return true
        }
        if persistedRuntimeMode() == "always-on" {
            return true
        }
        return persistedEngineDesiredState() == "running"
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}
