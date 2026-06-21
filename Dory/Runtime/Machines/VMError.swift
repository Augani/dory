import Foundation

enum VMError: Error, Sendable {
    case virtualizationUnavailable
    case downloadFailed(String)
    case diskBuildFailed(String)
    case cloudInitFailed(String)
    case vmNotFound(String)
    case vmStartFailed(String)
    case vmStopFailed(String)
    case sharedEngineUnavailable
}
