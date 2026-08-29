import Darwin
import Foundation

/// A descriptor that a child process receives at a deterministic descriptor number.
///
/// The parent descriptor is borrowed for the duration of `spawn`; ownership remains with
/// the caller. Child descriptor numbers 0, 1, and 2 are deliberately reserved for stdio.
public struct InheritedDescriptorMapping: Sendable, Equatable {
    public let parentDescriptor: Int32
    public let childDescriptor: Int32

    public init(parentDescriptor: Int32, childDescriptor: Int32) {
        self.parentDescriptor = parentDescriptor
        self.childDescriptor = childDescriptor
    }
}

public enum InheritedDescriptorSpawnError: Error, CustomStringConvertible, Equatable {
    case invalidParentDescriptor(Int32)
    case invalidChildDescriptor(Int32)
    case duplicateChildDescriptor(Int32)
    case invalidString(String)
    case descriptorDuplicationFailed(descriptor: Int32, code: Int32)
    case fileActionsInitializationFailed(Int32)
    case fileActionFailed(operation: String, code: Int32)
    case attributesInitializationFailed(Int32)
    case attributesConfigurationFailed(Int32)
    case spawnFailed(path: String, code: Int32)

    public var description: String {
        switch self {
        case .invalidParentDescriptor(let descriptor):
            return "parent descriptor \(descriptor) is not open"
        case .invalidChildDescriptor(let descriptor):
            return "child descriptor \(descriptor) is outside the allowed resource-slot range"
        case .duplicateChildDescriptor(let descriptor):
            return "child descriptor \(descriptor) is assigned more than once"
        case .invalidString(let field):
            return "\(field) contains a NUL byte or an invalid environment key"
        case .descriptorDuplicationFailed(let descriptor, let code):
            return "could not stage parent descriptor \(descriptor): \(String(cString: strerror(code)))"
        case .fileActionsInitializationFailed(let code):
            return "could not initialize child descriptor actions: \(String(cString: strerror(code)))"
        case .fileActionFailed(let operation, let code):
            return "could not configure child descriptor action \(operation): \(String(cString: strerror(code)))"
        case .attributesInitializationFailed(let code):
            return "could not initialize spawn attributes: \(String(cString: strerror(code)))"
        case .attributesConfigurationFailed(let code):
            return "could not configure spawn attributes: \(String(cString: strerror(code)))"
        case .spawnFailed(let path, let code):
            return "could not spawn \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Low-level process creation for helpers that need explicitly named inherited resources.
///
/// `HvProcess` owns lifecycle supervision and restart authority; this type provides the bounded
/// descriptor-transfer operation that Foundation's `Process` API does not expose.
public enum InheritedDescriptorSpawner {
    /// Resource slots are launch-envelope identifiers, not arbitrary process descriptor numbers.
    /// Keeping them bounded prevents an invalid internal plan from forcing a huge descriptor-table
    /// allocation in `F_DUPFD_CLOEXEC` or `posix_spawn`.
    public static let maximumChildDescriptor: Int32 = 1_023

    @discardableResult
    public static func spawn(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        inheritParentEnvironment: Bool = true,
        startSuspended: Bool = false,
        descriptorMappings: [InheritedDescriptorMapping],
        standardInputDescriptor: Int32? = nil,
        standardOutputDescriptor: Int32? = nil,
        standardErrorDescriptor: Int32? = nil
    ) throws -> pid_t {
        try validateStrings(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        )
        try validateMappings(descriptorMappings)

        var effectiveMappings = descriptorMappings
        if let standardInputDescriptor {
            try validateOpenDescriptor(standardInputDescriptor)
            effectiveMappings.append(InheritedDescriptorMapping(
                parentDescriptor: standardInputDescriptor,
                childDescriptor: STDIN_FILENO
            ))
        }
        if let standardOutputDescriptor {
            try validateOpenDescriptor(standardOutputDescriptor)
            effectiveMappings.append(InheritedDescriptorMapping(
                parentDescriptor: standardOutputDescriptor,
                childDescriptor: STDOUT_FILENO
            ))
        }
        if let standardErrorDescriptor {
            try validateOpenDescriptor(standardErrorDescriptor)
            effectiveMappings.append(InheritedDescriptorMapping(
                parentDescriptor: standardErrorDescriptor,
                childDescriptor: STDERR_FILENO
            ))
        }

        let maximumTarget = effectiveMappings.map(\.childDescriptor).max() ?? 2
        guard maximumTarget <= maximumChildDescriptor else {
            throw InheritedDescriptorSpawnError.invalidChildDescriptor(maximumTarget)
        }

        // Stage every source above all child targets. This removes dup2 ordering hazards when a
        // caller's source descriptor happens to equal another mapping's destination.
        var staged: [(descriptor: Int32, childDescriptor: Int32)] = []
        defer {
            for item in staged {
                close(item.descriptor)
            }
        }
        var nextStagingDescriptor = max(maximumTarget + 1, 3)
        for mapping in effectiveMappings {
            let duplicate = fcntl(
                mapping.parentDescriptor,
                F_DUPFD_CLOEXEC,
                nextStagingDescriptor
            )
            guard duplicate >= 0 else {
                let code = errno
                if code == EBADF {
                    throw InheritedDescriptorSpawnError.invalidParentDescriptor(mapping.parentDescriptor)
                }
                throw InheritedDescriptorSpawnError.descriptorDuplicationFailed(
                    descriptor: mapping.parentDescriptor,
                    code: code
                )
            }
            staged.append((duplicate, mapping.childDescriptor))
            if duplicate < Int32.max {
                nextStagingDescriptor = duplicate + 1
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        var code = posix_spawn_file_actions_init(&fileActions)
        guard code == 0 else {
            throw InheritedDescriptorSpawnError.fileActionsInitializationFailed(code)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        for item in staged {
            code = posix_spawn_file_actions_adddup2(
                &fileActions,
                item.descriptor,
                item.childDescriptor
            )
            guard code == 0 else {
                throw InheritedDescriptorSpawnError.fileActionFailed(
                    operation: "dup2(\(item.descriptor), \(item.childDescriptor))",
                    code: code
                )
            }
            code = posix_spawn_file_actions_addclose(&fileActions, item.descriptor)
            guard code == 0 else {
                throw InheritedDescriptorSpawnError.fileActionFailed(
                    operation: "close(\(item.descriptor))",
                    code: code
                )
            }
        }

        var attributes: posix_spawnattr_t?
        code = posix_spawnattr_init(&attributes)
        guard code == 0 else {
            throw InheritedDescriptorSpawnError.attributesInitializationFailed(code)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        code = posix_spawnattr_setsigmask(&attributes, &signalMask)
        guard code == 0 else {
            throw InheritedDescriptorSpawnError.attributesConfigurationFailed(code)
        }
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        code = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard code == 0 else {
            throw InheritedDescriptorSpawnError.attributesConfigurationFailed(code)
        }

        // On Darwin, this closes every non-stdio descriptor that is not explicitly mentioned by
        // a file action. Explicit signal defaults/mask prevent daemon process state from becoming
        // ambient authority or surprising helper lifecycle semantics.
        var spawnFlags = POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_SETSIGDEF
        if startSuspended {
            // Darwin guarantees the child is stopped before it executes user-space code. The
            // daemon uses this interval to authenticate the live mapped image before inherited
            // disk, kernel, or renderer-bootstrap descriptors can be consumed.
            spawnFlags |= POSIX_SPAWN_START_SUSPENDED
        }
        code = posix_spawnattr_setflags(&attributes, Int16(spawnFlags))
        guard code == 0 else {
            throw InheritedDescriptorSpawnError.attributesConfigurationFailed(code)
        }

        let argvStrings = [executablePath] + arguments
        let effectiveEnvironment = inheritParentEnvironment
            ? ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            : environment
        let environmentStrings = effectiveEnvironment.keys.sorted().map {
            "\($0)=\(effectiveEnvironment[$0]!)"
        }

        return try withMutableCStringArray(argvStrings) { argv in
            try withMutableCStringArray(environmentStrings) { environmentPointer in
                var childPID: pid_t = 0
                let result = posix_spawn(
                    &childPID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argv,
                    environmentPointer
                )
                guard result == 0 else {
                    throw InheritedDescriptorSpawnError.spawnFailed(
                        path: executablePath,
                        code: result
                    )
                }
                return childPID
            }
        }
    }

    private static func validateMappings(_ mappings: [InheritedDescriptorMapping]) throws {
        var targets: Set<Int32> = []
        for mapping in mappings {
            guard mapping.parentDescriptor >= 0,
                  fcntl(mapping.parentDescriptor, F_GETFD) >= 0 else {
                throw InheritedDescriptorSpawnError.invalidParentDescriptor(mapping.parentDescriptor)
            }
            guard (3...maximumChildDescriptor).contains(mapping.childDescriptor) else {
                throw InheritedDescriptorSpawnError.invalidChildDescriptor(mapping.childDescriptor)
            }
            guard targets.insert(mapping.childDescriptor).inserted else {
                throw InheritedDescriptorSpawnError.duplicateChildDescriptor(mapping.childDescriptor)
            }
        }
    }

    private static func validateOpenDescriptor(_ descriptor: Int32) throws {
        guard descriptor >= 0, fcntl(descriptor, F_GETFD) >= 0 else {
            throw InheritedDescriptorSpawnError.invalidParentDescriptor(descriptor)
        }
    }

    private static func validateStrings(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) throws {
        guard !executablePath.utf8.contains(0) else {
            throw InheritedDescriptorSpawnError.invalidString("executable path")
        }
        for (index, argument) in arguments.enumerated() where argument.utf8.contains(0) {
            throw InheritedDescriptorSpawnError.invalidString("argument \(index)")
        }
        for (key, value) in environment {
            guard !key.isEmpty,
                  !key.contains("="),
                  !key.utf8.contains(0),
                  !value.utf8.contains(0) else {
                throw InheritedDescriptorSpawnError.invalidString("environment")
            }
        }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        var pointers = strings.map { strdup($0) }
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
