import Darwin
import DorydKit
import Foundation

private let usage = """
usage: dory-linux-calibration launch \\
  --runner-app PATH --kernel PATH --kernel-sha256 SHA256 \\
  --rootfs PATH --rootfs-sha256 SHA256 \\
  --gvproxy PATH --gvproxy-sha256 SHA256 --workroot ABSENT_ABSOLUTE_PATH \\
  [--memory-mb 8192] [--cpus 8] [--display-width 1920] [--display-height 1080] \\
  --confirm I-UNDERSTAND-THIS-IS-NOT-RELEASE-QUALIFICATION

       dory-linux-calibration exec --agent-socket PATH \\
  [--timeout-ms 30000] [--output-limit-bytes 1048576] -- ARGV...

The workroot must not exist. This command emits calibration evidence only; it cannot qualify or
publish a release and never reads or mutates Dory's production support catalog. The exec command
connects only to the supplied calibration guest-agent socket; timeout is capped at 600000 ms and
each output stream is capped at 16777216 bytes.
"""

private func fail(_ message: String, status: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(status)
}

private func runLaunch(_ arguments: [String]) {
    let allowedOptions: Set<String> = [
        "--runner-app",
        "--kernel",
        "--kernel-sha256",
        "--rootfs",
        "--rootfs-sha256",
        "--gvproxy",
        "--gvproxy-sha256",
        "--workroot",
        "--memory-mb",
        "--cpus",
        "--display-width",
        "--display-height",
        "--confirm",
    ]
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let option = arguments[index]
        guard allowedOptions.contains(option) else {
            fail("unknown option \(option)")
        }
        guard values[option] == nil else {
            fail("duplicate option \(option)")
        }
        guard index + 1 < arguments.count else {
            fail("\(option) requires a value")
        }
        values[option] = arguments[index + 1]
        index += 2
    }

    func required(_ name: String) -> String {
        guard let value = values[name], !value.isEmpty else {
            fail("missing \(name)")
        }
        return value
    }

    func unsigned<T: FixedWidthInteger & UnsignedInteger>(
        _ name: String,
        default fallback: T
    ) -> T {
        guard let raw = values[name] else { return fallback }
        guard let value = T(raw), value > 0 else {
            fail("\(name) requires a positive integer")
        }
        return value
    }

    let configuration = DoryLinuxVMCalibrationConfiguration(
        runnerAppPath: required("--runner-app"),
        kernelPath: required("--kernel"),
        kernelSHA256: required("--kernel-sha256"),
        rootfsPath: required("--rootfs"),
        rootfsSHA256: required("--rootfs-sha256"),
        gvproxyPath: required("--gvproxy"),
        gvproxySHA256: required("--gvproxy-sha256"),
        workrootPath: required("--workroot"),
        memoryMB: unsigned("--memory-mb", default: UInt64(8_192)),
        virtualCPUCount: unsigned("--cpus", default: UInt16(8)),
        displayWidthPixels: unsigned(
            "--display-width", default: UInt32(1_920)
        ),
        displayHeightPixels: unsigned(
            "--display-height", default: UInt32(1_080)
        ),
        confirmation: required("--confirm")
    )

    do {
        try DoryLinuxVMCalibrationLauncher.run(configuration)
    } catch {
        fail("\(error)", status: 1)
    }
}

private func runExec(_ arguments: [String]) {
    let configuration: DoryLinuxVMCalibrationExecConfiguration
    do {
        configuration = try DoryLinuxVMCalibrationExec.parse(arguments: arguments)
    } catch {
        fail("\(error)")
    }
    do {
        let result = try DoryLinuxVMCalibrationExec.execute(configuration)
        let json = try DoryLinuxVMCalibrationExec.canonicalJSON(for: result)
        FileHandle.standardOutput.write(json + Data([0x0a]))
        exit(DoryLinuxVMCalibrationExec.processExitStatus(for: result))
    } catch {
        fail("\(error)", status: 1)
    }
}

private let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("expected the launch or exec command")
}
switch command {
case "launch":
    runLaunch(Array(arguments.dropFirst()))
case "exec":
    runExec(Array(arguments.dropFirst()))
default:
    fail("expected the launch or exec command")
}
