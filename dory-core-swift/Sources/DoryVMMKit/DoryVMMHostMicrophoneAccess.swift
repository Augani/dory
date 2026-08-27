import AppKit
@preconcurrency import AVFoundation
import Foundation

enum DoryVMMHostMicrophoneAccessError: Error, CustomStringConvertible, Equatable {
    case denied
    case restricted
    case requestTimedOut

    var description: String {
        switch self {
        case .denied:
            "Mac microphone access is denied. Enable Dory Linux in System Settings > Privacy & Security > Microphone, or disable Microphone for this desktop."
        case .restricted:
            "Mac microphone access is restricted by system policy. Disable Microphone for this desktop or ask the Mac administrator to allow it."
        case .requestTimedOut:
            "Mac microphone permission was not resolved in time. Try again and answer the macOS permission prompt, or disable Microphone for this desktop."
        }
    }
}

@MainActor
enum DoryVMMHostMicrophoneAccess {
    static func requireAuthorization(
        timeout: TimeInterval = 60,
        authorizationStatus: () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        prepareApplicationForPrompt: () -> Void = {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.activate()
        },
        requestAccess: (@escaping @Sendable (Bool) -> Void) -> Void = { completion in
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        }
    ) throws {
        switch authorizationStatus() {
        case .authorized:
            return
        case .denied:
            throw DoryVMMHostMicrophoneAccessError.denied
        case .restricted:
            throw DoryVMMHostMicrophoneAccessError.restricted
        case .notDetermined:
            break
        @unknown default:
            throw DoryVMMHostMicrophoneAccessError.restricted
        }

        prepareApplicationForPrompt()
        let result = PermissionResult()
        requestAccess { granted in result.resolve(granted) }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while result.value == nil, Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.05)))
        }
        guard let granted = result.value else {
            throw DoryVMMHostMicrophoneAccessError.requestTimedOut
        }
        guard granted else {
            throw DoryVMMHostMicrophoneAccessError.denied
        }
    }

    private final class PermissionResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: Bool?

        var value: Bool? {
            lock.withLock { storedValue }
        }

        func resolve(_ value: Bool) {
            lock.withLock {
                if storedValue == nil { storedValue = value }
            }
        }
    }
}
