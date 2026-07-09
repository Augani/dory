import Darwin
import Foundation

enum DorydLaunchAgent {
    static let label = "dev.dory.doryd"
    static let stateDirectory = "\(NSHomeDirectory())/.dory"
    static let logPath = "\(NSHomeDirectory())/.dory/doryd.log"
    private static let bootstrapRetryCount = 20

    struct Install: Sendable, Equatable {
        var plistPath: String
        var programPath: String
        var plistContents: String
    }

    struct Configuration: Sendable, Equatable {
        var domainSuffix: String
        var idleSleepAfterSeconds: UInt32
        var dnsPort: UInt16
        var httpProxyPort: UInt16
        var httpsProxyPort: UInt16
        var hostCLIEnabled: Bool
        var cpuCount: UInt16
        var memoryMB: UInt32

        nonisolated init(
            domainSuffix: String = "dory.local",
            idleSleepAfterSeconds: UInt32 = 300,
            dnsPort: UInt16 = 15353,
            httpProxyPort: UInt16 = 8080,
            httpsProxyPort: UInt16 = 8443,
            hostCLIEnabled: Bool = true,
            cpuCount: UInt16 = 2,
            memoryMB: UInt32 = 2048
        ) {
            self.domainSuffix = domainSuffix
            self.idleSleepAfterSeconds = idleSleepAfterSeconds
            self.dnsPort = dnsPort
            self.httpProxyPort = httpProxyPort
            self.httpsProxyPort = httpsProxyPort
            self.hostCLIEnabled = hostCLIEnabled
            self.cpuCount = max(1, cpuCount)
            self.memoryMB = max(256, memoryMB)
        }
    }

    struct Status: Sendable, Equatable {
        var loaded: Bool
        var plistPath: String?
        var programPath: String?
    }

    enum Decision: Sendable, Equatable {
        case unavailable(String)
        case upToDate
        case bootstrap
        case replace
    }

    struct CommandResult: Sendable, Equatable {
        var status: Int32
        var stdout: String
        var stderr: String

        var ok: Bool { status == 0 }
    }

    typealias Runner = @Sendable ([String]) async -> CommandResult

    static func ensureCurrent(
        bundle: Bundle = .main,
        launchAgentsDirectory: URL? = nil,
        configuration: Configuration = Configuration(),
        bootstrapRetryDelay: Duration = .milliseconds(250),
        runner: @escaping Runner = runLaunchctl
    ) async -> Bool {
        guard let current = currentInstall(
            bundle: bundle,
            launchAgentsDirectory: launchAgentsDirectory,
            configuration: configuration
        ) else { return false }
        let plistChanged: Bool
        do {
            plistChanged = try writeCurrentInstall(current)
        } catch {
            return false
        }
        let uid = getuid()
        let service = serviceTarget(uid: uid)
        let print = await runner(["print", service])
        let status = print.ok ? parseStatus(print.stdout) : nil

        switch decision(
            status: status,
            currentPlist: current.plistPath,
            currentProgram: current.programPath,
            currentPlistChanged: plistChanged
        ) {
        case .upToDate:
            return true
        case .bootstrap:
            return await bootstrapAndKickstart(
                uid: uid,
                plistPath: current.plistPath,
                retryDelay: bootstrapRetryDelay,
                runner: runner
            )
        case .replace:
            _ = await runner(["bootout", service])
            return await bootstrapAndKickstart(
                uid: uid,
                plistPath: current.plistPath,
                retryDelay: bootstrapRetryDelay,
                runner: runner
            )
        case .unavailable:
            return false
        }
    }

    private static func bootstrapAndKickstart(
        uid: uid_t,
        plistPath: String,
        retryDelay: Duration,
        runner: @escaping Runner
    ) async -> Bool {
        let domain = domainTarget(uid: uid)
        let service = serviceTarget(uid: uid)
        for attempt in 0..<bootstrapRetryCount {
            let bootstrapped = await runner(["bootstrap", domain, plistPath])
            if bootstrapped.ok {
                _ = await runner(["kickstart", "-k", service])
                return true
            }

            let print = await runner(["print", service])
            let status = print.ok ? parseStatus(print.stdout) : nil
            if let status, status.loaded, normalize(status.plistPath) == normalize(plistPath) {
                _ = await runner(["kickstart", "-k", service])
                return true
            }

            if attempt < bootstrapRetryCount - 1 {
                try? await Task.sleep(for: retryDelay)
            }
        }
        return false
    }

    @discardableResult
    static func writeCurrentPlist(
        bundle: Bundle = .main,
        launchAgentsDirectory: URL? = nil,
        configuration: Configuration = Configuration()
    ) -> Bool {
        guard let current = currentInstall(
            bundle: bundle,
            launchAgentsDirectory: launchAgentsDirectory,
            configuration: configuration
        ) else { return false }
        do {
            _ = try writeCurrentInstall(current)
            return true
        } catch {
            return false
        }
    }

    static func decision(
        status: Status?,
        currentPlist: String?,
        currentProgram: String?,
        currentPlistChanged: Bool = false
    ) -> Decision {
        guard let currentPlist, !currentPlist.isEmpty,
              let currentProgram, !currentProgram.isEmpty else {
            return .unavailable("current doryd LaunchAgent is not bundled")
        }
        guard let status, status.loaded else {
            return .bootstrap
        }
        guard normalize(status.programPath) == normalize(currentProgram),
              normalize(status.plistPath) == normalize(currentPlist) else {
            return .replace
        }
        guard !currentPlistChanged else {
            return .replace
        }
        return .upToDate
    }

    static func parseStatus(_ output: String) -> Status {
        Status(
            loaded: output.contains("state = running") || output.contains("job state = running"),
            plistPath: value(for: "path", in: output),
            programPath: value(for: "program", in: output)
        )
    }

    static func currentInstall(
        bundle: Bundle,
        launchAgentsDirectory: URL? = nil,
        configuration: Configuration = Configuration()
    ) -> Install? {
        let bundleURL = bundle.bundleURL
        let program = bundleURL.appendingPathComponent("Contents/Helpers/doryd").path
        let helpersDirectory = bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: program),
              let launchAgentsDirectory = launchAgentsDirectory ?? defaultLaunchAgentsDirectory() else {
            return nil
        }
        let plist = launchAgentsDirectory.appendingPathComponent("\(label).plist").path
        return Install(
            plistPath: plist,
            programPath: program,
            plistContents: launchAgentPlist(
                program: program,
                helpersDirectory: helpersDirectory,
                configuration: configuration
            )
        )
    }

    static func serviceTarget(uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(label)"
    }

    static func domainTarget(uid: uid_t = getuid()) -> String {
        "gui/\(uid)"
    }

    private static func value(for key: String, in output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(key) = ") else { continue }
            let value = line.dropFirst(key.count + 3).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func normalize(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func defaultLaunchAgentsDirectory() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private static func writeCurrentInstall(_ install: Install) throws -> Bool {
        let url = URL(fileURLWithPath: install.plistPath)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing == install.plistContents {
            return false
        }
        try install.plistContents.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    static func launchAgentPlist(
        program: String,
        helpersDirectory: URL,
        configuration: Configuration = Configuration()
    ) -> String {
        let vmm = helpersDirectory.appendingPathComponent("dory-vmm").path
        let hv = helpersDirectory.appendingPathComponent("dory-hv").path
        let gvproxy = helpersDirectory.appendingPathComponent("gvproxy").path
        let resourcesDirectory = helpersDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(program))</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(label)</key>
                <true/>
            </dict>
            <key>EnvironmentVariables</key>
            <dict>
                <key>DORYD_VMM_HELPER</key>
                <string>\(xmlEscaped(vmm))</string>
                <key>DORYD_HV_HELPER</key>
                <string>\(xmlEscaped(hv))</string>
                <key>DORYD_GVPROXY</key>
                <string>\(xmlEscaped(gvproxy))</string>
                <key>DORYD_HELPERS_DIR</key>
                <string>\(xmlEscaped(helpersDirectory.path))</string>
                <key>DORYD_RESOURCES_DIR</key>
                <string>\(xmlEscaped(resourcesDirectory))</string>
                <key>DORYD_HOST_CLI</key>
                <string>\(configuration.hostCLIEnabled ? "1" : "0")</string>
                <key>DORYD_CPUS</key>
                <string>\(configuration.cpuCount)</string>
                <key>DORYD_MEMORY_MB</key>
                <string>\(configuration.memoryMB)</string>
                <key>DORYD_NETWORKING</key>
                <string>1</string>
                <key>DORYD_DOMAIN_SUFFIX</key>
                <string>\(xmlEscaped(configuration.domainSuffix))</string>
                <key>DORYD_IDLE_SLEEP_AFTER_SECONDS</key>
                <string>\(configuration.idleSleepAfterSeconds)</string>
                <key>DORYD_DNS_PORT</key>
                <string>\(configuration.dnsPort)</string>
                <key>DORYD_HTTP_PROXY_PORT</key>
                <string>\(configuration.httpProxyPort)</string>
                <key>DORYD_HTTPS_PROXY_PORT</key>
                <string>\(configuration.httpsProxyPort)</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(xmlEscaped(logPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscaped(logPath))</string>
        </dict>
        </plist>
        """
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func runLaunchctl(_ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return CommandResult(status: 127, stdout: "", stderr: "\(error)")
            }
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }
}
