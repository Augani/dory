import Darwin
import Foundation

/// Test-only campaign clock. Wall-clock changes cannot replenish a probe's budget.
struct PCGPUHarnessDeadline {
    let end: UInt64

    init(seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds > 0, seconds <= 86_400 else {
            throw PCGPUHarnessFailure.invalidDeadline
        }
        end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    private init(end: UInt64) { self.end = end }

    var remainingSeconds: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return now < end ? Double(end - now) / 1_000_000_000 : 0
    }

    func capped(seconds: TimeInterval) -> Self {
        Self(end: min(end, DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)))
    }
}

enum PCGPUHarnessFailure: Error {
    case invalidDeadline
    case guestNotRunning
    case softwareGraphics
    case agentNotReady
    case renderFailed
}

enum PCGPUHarnessResult {
    static func probePassed(_ receipt: [String: Any]) -> Bool {
        receipt["returncode"] as? Int32 == 0
            && receipt["terminatedByTimeout"] as? Bool == false
            && receipt["launchError"] == nil
    }

    static func requireSuccess(
        running: Bool, hardwareGraphics: Bool, agentReady: Bool, renderPassed: Bool
    ) throws {
        guard running else { throw PCGPUHarnessFailure.guestNotRunning }
        guard hardwareGraphics else { throw PCGPUHarnessFailure.softwareGraphics }
        guard agentReady else { throw PCGPUHarnessFailure.agentNotReady }
        guard renderPassed else { throw PCGPUHarnessFailure.renderFailed }
    }

    /// A failed stop must retain its backing instead of unlinking a possibly live disk.
    static func cleanup(directory: URL, stop: () throws -> Void) throws {
        try stop()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

enum PCGPUHarnessProcess {
    static func run(executable: String, arguments: [String], deadline: PCGPUHarnessDeadline) -> [String: Any] {
        let started = DispatchTime.now().uptimeNanoseconds
        var receipt: [String: Any] = ["command": [executable] + arguments]
        guard deadline.remainingSeconds > 0 else {
            receipt["terminatedByTimeout"] = true
            return receipt
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-gpu-probe-" + UUID().uuidString)
        let process = Process()
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            // Regular files avoid waiting for an undrained pipe before process exit. The
            // calibration command bounds each guest output; retain only a bounded excerpt.
            let stdoutURL = scratch.appendingPathComponent("stdout")
            let stderrURL = scratch.appendingPathComponent("stderr")
            for url in [stdoutURL, stderrURL] {
                try Data().write(to: url)
            }
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            defer { try? stdout.close() }
            let stderr = try FileHandle(forWritingTo: stderrURL)
            defer { try? stderr.close() }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            while process.isRunning && deadline.remainingSeconds > 0 {
                Thread.sleep(forTimeInterval: min(0.05, deadline.remainingSeconds))
            }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                let grace = try PCGPUHarnessDeadline(seconds: 2)
                while process.isRunning && grace.remainingSeconds > 0 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                let reap = try PCGPUHarnessDeadline(seconds: 2)
                while process.isRunning && reap.remainingSeconds > 0 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            receipt["terminatedByTimeout"] = timedOut
            if process.isRunning {
                receipt["launchError"] = "probe termination could not be confirmed"
            } else {
                process.waitUntilExit()
                receipt["returncode"] = process.terminationStatus
            }
            for (key, url) in [("stdout", stdoutURL), ("stderr", stderrURL)] {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 8192) ?? Data()
                receipt[key] = String(decoding: data, as: UTF8.self)
            }
        } catch {
            receipt["launchError"] = String(describing: error)
        }
        receipt["elapsedSeconds"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        return receipt
    }
}
