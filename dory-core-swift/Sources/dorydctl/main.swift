import Darwin
import DorydKit
import Foundation

enum DorydCtlError: Error, CustomStringConvertible {
    case daemon(String)
    case invalidProxy
    case timedOut
    case usage(String)

    var description: String {
        switch self {
        case let .daemon(message):
            message.isEmpty ? "doryd returned an error" : message
        case .invalidProxy:
            "doryd XPC proxy has an unexpected type"
        case .timedOut:
            "doryd request timed out"
        case let .usage(message):
            message
        }
    }
}

final class ReplyBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Result<T, Error> {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return .failure(DorydCtlError.timedOut)
        }
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(DorydCtlError.timedOut)
    }
}

final class DorydCtlClient {
    private let machServiceName: String
    private let timeout: TimeInterval

    init(machServiceName: String, timeout: TimeInterval) {
        self.machServiceName = machServiceName
        self.timeout = timeout
    }

    func withTimeout(atLeast minimumTimeout: TimeInterval) -> DorydCtlClient {
        guard minimumTimeout > timeout else {
            return self
        }
        return DorydCtlClient(machServiceName: machServiceName, timeout: minimumTimeout)
    }

    func call<T>(_ body: (DorydControl, @escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        let box = ReplyBox<T>()
        connection.remoteObjectInterface = NSXPCInterface(with: DorydControl.self)
        connection.invalidationHandler = {
            box.resume(.failure(DorydCtlError.daemon("doryd connection invalidated")))
        }
        connection.interruptionHandler = {
            box.resume(.failure(DorydCtlError.daemon("doryd connection interrupted")))
        }
        connection.resume()
        defer { connection.invalidate() }

        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            box.resume(.failure(error))
        }
        guard let proxy = remote as? DorydControl else {
            throw DorydCtlError.invalidProxy
        }
        body(proxy) { result in
            box.resume(result)
        }
        return try box.wait(timeout: timeout).get()
    }

    func command(_ body: (DorydControl, @escaping (Bool, String) -> Void) -> Void) throws -> NSDictionary {
        try call { proxy, finish in
            body(proxy) { ok, message in
                finish(.success(["ok": ok, "message": message] as NSDictionary))
            }
        }
    }

    func statusCommand(
        _ body: (DorydControl, @escaping (Bool, NSDictionary, String) -> Void) -> Void
    ) throws -> NSDictionary {
        try call { proxy, finish in
            body(proxy) { ok, body, message in
                if ok {
                    finish(.success(body))
                } else {
                    finish(.failure(DorydCtlError.daemon(message)))
                }
            }
        }
    }
}

struct ArgumentCursor {
    var values: [String]

    mutating func take(_ usage: String) throws -> String {
        guard !values.isEmpty else { throw DorydCtlError.usage(usage) }
        return values.removeFirst()
    }

    mutating func optionValue(_ name: String) throws -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        guard index + 1 < values.count else {
            throw DorydCtlError.usage("missing value for \(name)")
        }
        let value = values[index + 1]
        values.removeSubrange(index...(index + 1))
        return value
    }

    mutating func optionValues(_ name: String) throws -> [String] {
        var result: [String] = []
        while let value = try optionValue(name) {
            result.append(value)
        }
        return result
    }
}

func usage(exitCode: Int32 = 2) -> Never {
    print(
        """
        Usage:
          dorydctl [--mach-service NAME] [--timeout SECONDS] protocol-version
          dorydctl [global] socket-path
          dorydctl [global] engine status|start|stop|sleep|wake
          dorydctl [global] docker agent-info|ports|telemetry
          dorydctl [global] machine list
          dorydctl [global] machine status NAME
          dorydctl [global] machine create NAME --kernel PATH --rootfs PATH [--memory-mb N] [--cpus N] [--address HOST] [--share TAG=HOST:GUEST[:ro|rw]]
          dorydctl [global] machine update NAME [--memory-mb N] [--cpus N] [--address HOST]
          dorydctl [global] machine start|stop|delete NAME
          dorydctl [global] machine exec NAME [--json] [--cwd PATH] [--env KEY=VALUE] [--timeout-ms N] [--output-limit-bytes N] -- COMMAND [ARG...]
          dorydctl [global] machine shell NAME
          dorydctl [global] machine provision NAME --recipe RECIPE
          dorydctl [global] machine snapshots [NAME]
          dorydctl [global] machine snapshot NAME [--note NOTE] [--id ID]
          dorydctl [global] machine clone-snapshot NAME SNAPSHOT_ID NEW_NAME
          dorydctl [global] machine restore-snapshot NAME SNAPSHOT_ID
          dorydctl [global] machine delete-snapshot NAME SNAPSHOT_ID
          dorydctl [global] machine export-snapshot NAME SNAPSHOT_ID PATH
          dorydctl [global] machine import-snapshot PATH
          dorydctl [global] remote connect NAME --host HOST --user USER --private-key-id ID --remote-root PATH (--host-key KEY | --known-hosts PATH) [--port N] [--endpoint-unix PATH | --endpoint-tcp HOST:PORT]
          dorydctl [global] remote push NAME --local-root PATH [--remote-root PATH]
          dorydctl [global] remote status NAME
          dorydctl [global] network status|authorization-plan
          dorydctl [global] network replace-routes --json PATH|-
          dorydctl [global] network set-route HOST ADDRESS [--port N]
          dorydctl [global] balloon status|reconcile
          dorydctl [global] idle status|history|set|mode
          dorydctl [global] health
          dorydctl [global] doctor-json
          dorydctl [global] incidents [--limit N]
        """
    )
    exit(exitCode)
}

func emitJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func emitCommandResult(_ value: NSDictionary) throws {
    try emitJSON(value)
    if value["ok"] as? Bool == false {
        let message = value["message"] as? String ?? ""
        throw DorydCtlError.daemon(message)
    }
}

func positiveUInt64(_ raw: String, option: String) throws -> UInt64 {
    guard let value = UInt64(raw), value > 0 else {
        throw DorydCtlError.usage("\(option) must be a positive integer")
    }
    return value
}

func positiveInt(_ raw: String, option: String) throws -> Int {
    guard let value = Int(raw), value > 0 else {
        throw DorydCtlError.usage("\(option) must be a positive integer")
    }
    return value
}

func positiveUInt16(_ raw: String, option: String) throws -> UInt16 {
    guard let value = UInt16(raw), value > 0 else {
        throw DorydCtlError.usage("\(option) must be a positive integer less than 65536")
    }
    return value
}

func nonNegativeUInt64(_ raw: String, option: String) throws -> UInt64 {
    guard let value = UInt64(raw) else {
        throw DorydCtlError.usage("\(option) must be a non-negative integer")
    }
    return value
}

func machineExecControlTimeout(timeoutMs: UInt64) -> TimeInterval {
    let effectiveTimeoutMs: UInt64
    switch timeoutMs {
    case 0:
        effectiveTimeoutMs = 30_000
    default:
        effectiveTimeoutMs = min(timeoutMs, 600_000)
    }
    return TimeInterval(effectiveTimeoutMs) / 1000 + 10
}

func requiredOption(_ name: String, cursor: inout ArgumentCursor, usage: String) throws -> String {
    guard let value = try cursor.optionValue(name), !value.isEmpty else {
        throw DorydCtlError.usage(usage)
    }
    return value
}

func readJSON(path: String) throws -> Any {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    }
    return try JSONSerialization.jsonObject(with: data)
}

func machineDictionary(name: String, client: DorydCtlClient) throws -> NSDictionary {
    let rows: NSArray = try client.call { proxy, finish in
        proxy.machineList { body, message in
            message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
        }
    }
    guard let match = rows.compactMap({ $0 as? NSDictionary }).first(where: { $0["id"] as? String == name }) else {
        throw DorydCtlError.daemon("unknown machine: \(name)")
    }
    return match
}

func tcpEndpointParts(_ raw: String) throws -> (host: String, port: UInt16) {
    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]) else {
        throw DorydCtlError.usage("--endpoint-tcp must be HOST:PORT")
    }
    return (parts[0], port)
}

func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    var machService = ProcessInfo.processInfo.environment["DORYD_MACH_SERVICE"] ?? "dev.dory.doryd"
    var timeout = TimeInterval(ProcessInfo.processInfo.environment["DORYD_CTL_TIMEOUT"] ?? "") ?? 5

    while let first = args.first {
        switch first {
        case "--mach-service":
            args.removeFirst()
            guard let value = args.first else { throw DorydCtlError.usage("missing value for --mach-service") }
            machService = value
            args.removeFirst()
        case "--timeout":
            args.removeFirst()
            guard let value = args.first, let parsed = TimeInterval(value), parsed > 0 else {
                throw DorydCtlError.usage("--timeout must be a positive number")
            }
            timeout = parsed
            args.removeFirst()
        case "-h", "--help", "help":
            usage(exitCode: 0)
        default:
            let client = DorydCtlClient(machServiceName: machService, timeout: timeout)
            var cursor = ArgumentCursor(values: args)
            let command = try cursor.take("missing command")
            try run(command: command, cursor: &cursor, client: client)
            return
        }
    }
    usage()
}

func run(command: String, cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    switch command {
    case "protocol-version":
        let version: UInt32 = try client.call { proxy, finish in
            proxy.protocolVersion { finish(.success($0)) }
        }
        print(version)
    case "socket-path":
        let path: String = try client.call { proxy, finish in
            proxy.dorySocketPath { finish(.success($0)) }
        }
        print(path)
    case "engine":
        try runEngine(cursor: &cursor, client: client)
    case "docker":
        try runDocker(cursor: &cursor, client: client)
    case "machine":
        try runMachine(cursor: &cursor, client: client)
    case "remote":
        try runRemote(cursor: &cursor, client: client)
    case "network":
        try runNetwork(cursor: &cursor, client: client)
    case "balloon":
        try runBalloon(cursor: &cursor, client: client)
    case "idle":
        try runIdle(cursor: &cursor, client: client)
    case "health":
        let report: NSDictionary = try client.call { proxy, finish in
            proxy.health { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(report)
    case "doctor-json":
        let json: String = try client.call { proxy, finish in
            proxy.doctorJSON { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        print(json)
    case "incidents":
        let limit = try cursor.optionValue("--limit").map { try positiveInt($0, option: "--limit") } ?? 40
        let rows: NSArray = try client.call { proxy, finish in
            proxy.incidents(limit) { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(rows)
    default:
        throw DorydCtlError.usage("unknown command: \(command)")
    }
}

func runIdle(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let subcommand = try cursor.take("usage: dorydctl idle status|history|set|mode")
    switch subcommand {
    case "status":
        let status: NSDictionary = try client.call { proxy, finish in
            proxy.idleStatus { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(status)
    case "history":
        let limit = try cursor.optionValue("--limit").map { try positiveInt($0, option: "--limit") } ?? 40
        let rows: NSArray = try client.call { proxy, finish in
            proxy.idleHistory(limit) { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(rows)
    case "set":
        let key = try cursor.take("usage: dorydctl idle set KEY VALUE")
        let value = try cursor.take("usage: dorydctl idle set KEY VALUE")
        let status = try client.statusCommand { proxy, reply in
            proxy.idleSetPolicy(key, value: value, reply: reply)
        }
        try emitJSON(status)
    case "mode":
        let mode = try cursor.take("usage: dorydctl idle mode manual|auto-idle|always-on|battery-saver")
        let status = try client.statusCommand { proxy, reply in
            proxy.idleSetMode(mode, reply: reply)
        }
        try emitJSON(status)
    default:
        throw DorydCtlError.usage("unknown idle command: \(subcommand)")
    }
}

func runDocker(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let subcommand = try cursor.take("usage: dorydctl docker agent-info|ports|telemetry")
    let response: NSDictionary
    switch subcommand {
    case "agent-info", "info":
        response = try client.call { proxy, finish in
            proxy.dockerAgentInfo { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
    case "ports":
        response = try client.call { proxy, finish in
            proxy.dockerAgentPorts { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
    case "telemetry":
        response = try client.call { proxy, finish in
            proxy.dockerAgentTelemetry { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
    default:
        throw DorydCtlError.usage("unknown docker command: \(subcommand)")
    }
    try emitJSON(response)
}

func runEngine(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let subcommand = try cursor.take("usage: dorydctl engine status|start|stop|sleep|wake")
    switch subcommand {
    case "status":
        let status: NSDictionary = try client.call { proxy, finish in
            proxy.engineStatus { state, detail in
                finish(.success(["state": state, "detail": detail] as NSDictionary))
            }
        }
        try emitJSON(status)
    case "start":
        try emitCommandResult(try client.command { $0.engineStart(reply: $1) })
    case "stop":
        try emitCommandResult(try client.command { $0.engineStop(reply: $1) })
    case "sleep":
        try emitCommandResult(try client.command { $0.engineSleep(reply: $1) })
    case "wake":
        try emitCommandResult(try client.command { $0.engineWake(reply: $1) })
    default:
        throw DorydCtlError.usage("unknown engine command: \(subcommand)")
    }
}

func runRemote(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let subcommand = try cursor.take("usage: dorydctl remote connect|push|status")
    switch subcommand {
    case "connect":
        let name = try cursor.take("usage: dorydctl remote connect NAME --host HOST --user USER --private-key-id ID --remote-root PATH")
        let usage = "usage: dorydctl remote connect NAME --host HOST --user USER --private-key-id ID --remote-root PATH (--host-key KEY | --known-hosts PATH)"
        var config: [String: Any] = [
            "id": name,
            "host": try requiredOption("--host", cursor: &cursor, usage: usage),
            "user": try requiredOption("--user", cursor: &cursor, usage: usage),
            "privateKeyID": try requiredOption("--private-key-id", cursor: &cursor, usage: usage),
            "remoteRoot": try requiredOption("--remote-root", cursor: &cursor, usage: usage),
        ]
        if let port = try cursor.optionValue("--port") {
            config["port"] = try positiveUInt16(port, option: "--port")
        }
        if let build = try cursor.optionValue("--build") {
            config["build"] = build
        }
        if let hostKey = try cursor.optionValue("--host-key") {
            config["hostKeyType"] = "pinned"
            config["hostKey"] = hostKey
        } else if let knownHosts = try cursor.optionValue("--known-hosts") {
            config["hostKeyType"] = "knownHosts"
            config["knownHostsPath"] = knownHosts
            if let host = try cursor.optionValue("--known-hosts-host") {
                config["knownHostsHost"] = host
            }
            if let port = try cursor.optionValue("--known-hosts-port") {
                config["knownHostsPort"] = try positiveUInt16(port, option: "--known-hosts-port")
            }
        } else {
            throw DorydCtlError.usage(usage)
        }
        if let endpoint = try cursor.optionValue("--endpoint-tcp") {
            let parsed = try tcpEndpointParts(endpoint)
            config["endpointType"] = "tcp"
            config["endpointHost"] = parsed.host
            config["endpointPort"] = parsed.port
        } else {
            config["endpointType"] = "unix"
            config["endpointPath"] = try cursor.optionValue("--endpoint-unix") ?? "/run/dory/agent.sock"
        }
        let info = try client.statusCommand { proxy, reply in
            proxy.remoteConnect(config as NSDictionary, reply: reply)
        }
        try emitJSON(info)
    case "push":
        let name = try cursor.take("usage: dorydctl remote push NAME --local-root PATH [--remote-root PATH]")
        let localRoot = try requiredOption(
            "--local-root",
            cursor: &cursor,
            usage: "usage: dorydctl remote push NAME --local-root PATH [--remote-root PATH]"
        )
        let remoteRoot = try cursor.optionValue("--remote-root") ?? ""
        let stats: NSDictionary = try client.call { proxy, finish in
            proxy.remotePush(name, localRoot: localRoot, remoteRoot: remoteRoot) { ok, body, message in
                ok ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(stats)
    case "status":
        let name = try cursor.take("usage: dorydctl remote status NAME")
        let status: NSDictionary = try client.call { proxy, finish in
            proxy.remoteStatus(name) { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(status)
    default:
        throw DorydCtlError.usage("unknown remote command: \(subcommand)")
    }
}

func runNetwork(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let subcommand = try cursor.take("usage: dorydctl network status|authorization-plan|replace-routes|set-route")
    switch subcommand {
    case "status":
        let status: NSDictionary = try client.call { proxy, finish in
            proxy.networkStatus { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(status)
    case "authorization-plan", "auth-plan":
        let plan: NSDictionary = try client.call { proxy, finish in
            proxy.networkAuthorizationPlan { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(plan)
    case "replace-routes":
        let jsonPath = try requiredOption(
            "--json",
            cursor: &cursor,
            usage: "usage: dorydctl network replace-routes --json PATH|-"
        )
        guard let routes = try readJSON(path: jsonPath) as? NSArray else {
            throw DorydCtlError.usage("--json must contain an array of route objects")
        }
        try emitCommandResult(try client.command { proxy, reply in
            proxy.networkReplaceRoutes(routes, reply: reply)
        })
    case "set-route":
        let hostname = try cursor.take("usage: dorydctl network set-route HOST ADDRESS [--port N]")
        let address = try cursor.take("usage: dorydctl network set-route HOST ADDRESS [--port N]")
        let port = try cursor.optionValue("--port").map { try positiveUInt16($0, option: "--port") } ?? 80
        let routes: NSArray = [[
            "hostname": hostname,
            "address": address,
            "port": port,
        ] as NSDictionary]
        try emitCommandResult(try client.command { proxy, reply in
            proxy.networkReplaceRoutes(routes, reply: reply)
        })
    default:
        throw DorydCtlError.usage("unknown network command: \(subcommand)")
    }
}

func runBalloon(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let subcommand = try cursor.take("usage: dorydctl balloon status|reconcile")
    let plan: NSDictionary
    switch subcommand {
    case "status":
        plan = try client.call { proxy, finish in
            proxy.balloonStatus { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
    case "reconcile":
        plan = try client.call { proxy, finish in
            proxy.balloonReconcile { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
    default:
        throw DorydCtlError.usage("unknown balloon command: \(subcommand)")
    }
    try emitJSON(plan)
}

func runMachine(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let subcommand = try cursor.take("usage: dorydctl machine list|status|create|update|start|stop|delete|exec|shell|provision|snapshots|snapshot")
    switch subcommand {
    case "list":
        let rows: NSArray = try client.call { proxy, finish in
            proxy.machineList { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(rows)
    case "status":
        let name = try cursor.take("usage: dorydctl machine status NAME")
        try emitJSON(try machineDictionary(name: name, client: client))
    case "create":
        let name = try cursor.take("usage: dorydctl machine create NAME --kernel PATH --rootfs PATH")
        guard let kernel = try cursor.optionValue("--kernel"),
              let rootfs = try cursor.optionValue("--rootfs") else {
            throw DorydCtlError.usage("usage: dorydctl machine create NAME --kernel PATH --rootfs PATH")
        }
        let memoryMB = try cursor.optionValue("--memory-mb").map { try positiveUInt64($0, option: "--memory-mb") } ?? 2048
        let cpuCount = try cursor.optionValue("--cpus").map { try positiveInt($0, option: "--cpus") } ?? 2
        let shares = try cursor.optionValues("--share").map { try DoryMachineShareConfiguration(argument: $0) }
        var config: [String: Any] = [
            "id": name,
            "kernelPath": kernel,
            "rootfsPath": rootfs,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
        ]
        if let address = try cursor.optionValue("--address") {
            config["address"] = address
        }
        if !shares.isEmpty {
            config["shares"] = shares.map { share in
                [
                    "tag": share.tag,
                    "hostPath": share.hostPath,
                    "guestPath": share.guestPath,
                    "readOnly": share.readOnly,
                ] as NSDictionary
            }
        }
        let status = try client.statusCommand { proxy, reply in
            proxy.machineCreate(config as NSDictionary, reply: reply)
        }
        try emitJSON(status)
    case "start":
        let name = try cursor.take("usage: dorydctl machine start NAME")
        try emitJSON(try client.statusCommand { $0.machineStart(name, reply: $1) })
    case "stop":
        let name = try cursor.take("usage: dorydctl machine stop NAME")
        try emitJSON(try client.statusCommand { $0.machineStop(name, reply: $1) })
    case "update":
        try runMachineUpdate(cursor: &cursor, client: client)
    case "delete", "rm":
        let name = try cursor.take("usage: dorydctl machine delete NAME")
        try emitCommandResult(try client.command { $0.machineDelete(name, reply: $1) })
    case "exec":
        try runMachineExec(cursor: &cursor, client: client)
    case "shell":
        try runMachineShell(cursor: &cursor, client: client)
    case "provision":
        try runMachineProvision(cursor: &cursor, client: client)
    case "snapshots":
        let name = cursor.values.isEmpty ? "" : try cursor.take("usage: dorydctl machine snapshots [NAME]")
        guard cursor.values.isEmpty else {
            throw DorydCtlError.usage("unexpected machine snapshots argument: \(cursor.values[0])")
        }
        let rows: NSArray = try client.call { proxy, finish in
            proxy.machineSnapshots(name) { body, message in
                message.isEmpty ? finish(.success(body)) : finish(.failure(DorydCtlError.daemon(message)))
            }
        }
        try emitJSON(rows)
    case "snapshot":
        try runMachineSnapshot(cursor: &cursor, client: client)
    case "clone-snapshot":
        let name = try cursor.take("usage: dorydctl machine clone-snapshot NAME SNAPSHOT_ID NEW_NAME")
        let snapshotID = try cursor.take("usage: dorydctl machine clone-snapshot NAME SNAPSHOT_ID NEW_NAME")
        let newName = try cursor.take("usage: dorydctl machine clone-snapshot NAME SNAPSHOT_ID NEW_NAME")
        guard cursor.values.isEmpty else {
            throw DorydCtlError.usage("unexpected clone-snapshot argument: \(cursor.values[0])")
        }
        try emitJSON(try client.statusCommand { proxy, reply in
            proxy.machineCloneSnapshot(name, snapshotID: snapshotID, newID: newName, reply: reply)
        })
    case "restore-snapshot":
        let name = try cursor.take("usage: dorydctl machine restore-snapshot NAME SNAPSHOT_ID")
        let snapshotID = try cursor.take("usage: dorydctl machine restore-snapshot NAME SNAPSHOT_ID")
        guard cursor.values.isEmpty else {
            throw DorydCtlError.usage("unexpected restore-snapshot argument: \(cursor.values[0])")
        }
        try emitJSON(try client.statusCommand { proxy, reply in
            proxy.machineRestoreSnapshot(name, snapshotID: snapshotID, reply: reply)
        })
    case "delete-snapshot":
        let name = try cursor.take("usage: dorydctl machine delete-snapshot NAME SNAPSHOT_ID")
        let snapshotID = try cursor.take("usage: dorydctl machine delete-snapshot NAME SNAPSHOT_ID")
        guard cursor.values.isEmpty else {
            throw DorydCtlError.usage("unexpected delete-snapshot argument: \(cursor.values[0])")
        }
        try emitCommandResult(try client.command { proxy, reply in
            proxy.machineDeleteSnapshot(name, snapshotID: snapshotID, reply: reply)
        })
    case "export-snapshot":
        let name = try cursor.take("usage: dorydctl machine export-snapshot NAME SNAPSHOT_ID PATH")
        let snapshotID = try cursor.take("usage: dorydctl machine export-snapshot NAME SNAPSHOT_ID PATH")
        let path = try cursor.take("usage: dorydctl machine export-snapshot NAME SNAPSHOT_ID PATH")
        guard cursor.values.isEmpty else {
            throw DorydCtlError.usage("unexpected export-snapshot argument: \(cursor.values[0])")
        }
        try emitCommandResult(try client.command { proxy, reply in
            proxy.machineExportSnapshot(name, snapshotID: snapshotID, path: path, reply: reply)
        })
    case "import-snapshot":
        let path = try cursor.take("usage: dorydctl machine import-snapshot PATH")
        guard cursor.values.isEmpty else {
            throw DorydCtlError.usage("unexpected import-snapshot argument: \(cursor.values[0])")
        }
        let imported = try client.statusCommand { proxy, reply in
            proxy.machineImportSnapshot(path, reply: reply)
        }
        try emitJSON(imported)
    default:
        throw DorydCtlError.usage("unknown machine command: \(subcommand)")
    }
}

func runMachineUpdate(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let usage = "usage: dorydctl machine update NAME [--memory-mb N] [--cpus N] [--address HOST]"
    let name = try cursor.take(usage)
    var config: [String: Any] = [:]
    if let memory = try cursor.optionValue("--memory-mb") {
        config["memoryMB"] = try positiveUInt64(memory, option: "--memory-mb")
    }
    if let cpus = try cursor.optionValue("--cpus") {
        config["cpuCount"] = try positiveInt(cpus, option: "--cpus")
    }
    if let address = try cursor.optionValue("--address") {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DorydCtlError.usage("missing value for --address")
        }
        config["address"] = address
    }
    guard !config.isEmpty else {
        throw DorydCtlError.usage(usage)
    }
    guard cursor.values.isEmpty else {
        throw DorydCtlError.usage("unexpected machine update argument: \(cursor.values[0])")
    }
    let updateClient = client.withTimeout(atLeast: 120)
    let status = try updateClient.statusCommand { proxy, reply in
        proxy.machineUpdate(name, config: config as NSDictionary, reply: reply)
    }
    try emitJSON(status)
}

func runMachineSnapshot(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let usage = "usage: dorydctl machine snapshot NAME [--note NOTE] [--id ID]"
    let name = try cursor.take(usage)
    var request: [String: Any] = [:]
    if let note = try cursor.optionValue("--note") {
        request["note"] = note
    }
    if let id = try cursor.optionValue("--id") {
        request["snapshotID"] = id
    }
    guard cursor.values.isEmpty else {
        throw DorydCtlError.usage("unexpected machine snapshot argument: \(cursor.values[0])")
    }
    let snapshot = try client.statusCommand { proxy, reply in
        proxy.machineSnapshot(name, request: request as NSDictionary, reply: reply)
    }
    try emitJSON(snapshot)
}

func runMachineProvision(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let usage = "usage: dorydctl machine provision NAME --recipe RECIPE"
    let name = try cursor.take(usage)
    let recipe = try cursor.optionValue("--recipe") ?? "rust"
    guard cursor.values.isEmpty else {
        throw DorydCtlError.usage("unexpected machine provision argument: \(cursor.values[0])")
    }
    let provisionClient = client.withTimeout(atLeast: machineExecControlTimeout(timeoutMs: 600_000) * 2)
    let result = try provisionClient.statusCommand { proxy, reply in
        proxy.machineProvision(name, request: ["recipe": recipe] as NSDictionary, reply: reply)
    }
    try emitJSON(result)
}

func runMachineShell(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let name = try cursor.take("usage: dorydctl machine shell NAME")
    guard cursor.values.isEmpty else {
        throw DorydCtlError.usage("unexpected machine shell argument: \(cursor.values[0])")
    }
    let status = try machineDictionary(name: name, client: client)
    guard status["state"] as? String == "running" else {
        throw DorydCtlError.daemon("machine is not running: \(name)")
    }
    guard let shellSocketPath = status["shellSocketPath"] as? String, !shellSocketPath.isEmpty else {
        throw DorydCtlError.daemon("machine shell is unavailable: \(name)")
    }
    try bridgeUnixSocket(path: shellSocketPath)
}

func runMachineExec(cursor: inout ArgumentCursor, client: DorydCtlClient) throws {
    let usage = "usage: dorydctl machine exec NAME [--json] [--cwd PATH] [--env KEY=VALUE] [--timeout-ms N] [--output-limit-bytes N] -- COMMAND [ARG...]"
    let name = try cursor.take(usage)
    var jsonOutput = false
    var request: [String: Any] = [
        "cwd": "",
        "timeoutMs": UInt64(30_000),
        "outputLimitBytes": UInt64(1024 * 1024),
        "env": [] as [NSDictionary],
    ]
    var envRows: [NSDictionary] = []
    var argv: [String] = []

    while !cursor.values.isEmpty {
        let item = cursor.values.removeFirst()
        switch item {
        case "--json":
            jsonOutput = true
        case "--cwd":
            guard let value = cursor.values.first else { throw DorydCtlError.usage("missing value for --cwd") }
            request["cwd"] = value
            cursor.values.removeFirst()
        case "--env":
            guard let value = cursor.values.first else { throw DorydCtlError.usage("missing value for --env") }
            cursor.values.removeFirst()
            guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                throw DorydCtlError.usage("--env must be KEY=VALUE")
            }
            envRows.append([
                "key": String(value[..<equals]),
                "value": String(value[value.index(after: equals)...]),
            ] as NSDictionary)
        case "--timeout-ms":
            guard let value = cursor.values.first else { throw DorydCtlError.usage("missing value for --timeout-ms") }
            request["timeoutMs"] = try nonNegativeUInt64(value, option: "--timeout-ms")
            cursor.values.removeFirst()
        case "--output-limit-bytes":
            guard let value = cursor.values.first else {
                throw DorydCtlError.usage("missing value for --output-limit-bytes")
            }
            request["outputLimitBytes"] = try nonNegativeUInt64(value, option: "--output-limit-bytes")
            cursor.values.removeFirst()
        case "--":
            argv = cursor.values
            cursor.values.removeAll()
        default:
            argv = [item] + cursor.values
            cursor.values.removeAll()
        }
    }

    guard !argv.isEmpty else { throw DorydCtlError.usage(usage) }
    request["argv"] = argv
    request["env"] = envRows
    let timeoutMs = request["timeoutMs"] as? UInt64 ?? 30_000
    let execClient = client.withTimeout(atLeast: machineExecControlTimeout(timeoutMs: timeoutMs))

    let result: NSDictionary = try execClient.statusCommand { proxy, reply in
        proxy.machineExec(name, request: request as NSDictionary, reply: reply)
    }
    if jsonOutput {
        try emitJSON(machineExecJSON(machine: name, argv: argv, result: result))
    } else {
        if let stdout = result["stdout"] as? Data, !stdout.isEmpty {
            FileHandle.standardOutput.write(stdout)
        }
        if let stderr = result["stderr"] as? Data, !stderr.isEmpty {
            FileHandle.standardError.write(stderr)
        }
    }
    if result["timedOut"] as? Bool == true {
        FileHandle.standardError.write(Data("dorydctl: machine exec timed out\n".utf8))
    }
    if result["stdoutTruncated"] as? Bool == true {
        FileHandle.standardError.write(Data("dorydctl: stdout truncated\n".utf8))
    }
    if result["stderrTruncated"] as? Bool == true {
        FileHandle.standardError.write(Data("dorydctl: stderr truncated\n".utf8))
    }
    let exitCode = (result["exitCode"] as? NSNumber)?.int32Value ?? 1
    if exitCode != 0 {
        exit(exitCode)
    }
}

func machineExecJSON(machine: String, argv: [String], result: NSDictionary) -> NSDictionary {
    let stdout = result["stdout"] as? Data ?? Data()
    let stderr = result["stderr"] as? Data ?? Data()
    let exitCode = (result["exitCode"] as? NSNumber)?.intValue ?? 1
    return [
        "schema": "dev.dory.machine.exec",
        "version": 1,
        "machine": machine,
        "argv": argv,
        "exitCode": exitCode,
        "timedOut": result["timedOut"] as? Bool ?? false,
        "stdout": String(decoding: stdout, as: UTF8.self),
        "stderr": String(decoding: stderr, as: UTF8.self),
        "stdoutBase64": stdout.base64EncodedString(),
        "stderrBase64": stderr.base64EncodedString(),
        "stdoutTruncated": result["stdoutTruncated"] as? Bool ?? false,
        "stderrTruncated": result["stderrTruncated"] as? Bool ?? false,
    ] as NSDictionary
}

final class RawTerminalMode {
    private let fd: Int32
    private var original = termios()
    private var active = false

    init(fd: Int32) {
        self.fd = fd
        guard isatty(fd) == 1, tcgetattr(fd, &original) == 0 else { return }
        var raw = original
        cfmakeraw(&raw)
        active = tcsetattr(fd, TCSANOW, &raw) == 0
    }

    deinit {
        if active {
            var restore = original
            tcsetattr(fd, TCSANOW, &restore)
        }
    }
}

func bridgeUnixSocket(path: String) throws {
    signal(SIGPIPE, SIG_IGN)
    let socketFD = try connectUnixSocket(path: path)
    defer { close(socketFD) }
    let rawMode = RawTerminalMode(fd: STDIN_FILENO)
    defer { withExtendedLifetime(rawMode) {} }

    DispatchQueue.global(qos: .userInitiated).async {
        pump(from: STDIN_FILENO, to: socketFD)
        shutdown(socketFD, SHUT_WR)
    }
    pump(from: socketFD, to: STDOUT_FILENO)
}

func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DorydCtlError.daemon("socket: \(String(cString: strerror(errno)))") }
    do {
        var address = try unixAddress(path: path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw DorydCtlError.daemon("connect \(path): \(String(cString: strerror(errno)))")
        }
        return fd
    } catch {
        close(fd)
        throw error
    }
}

func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw DorydCtlError.daemon("socket path is too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}

func pump(from inputFD: Int32, to outputFD: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    let capacity = buffer.count
    while true {
        let count = buffer.withUnsafeMutableBytes { read(inputFD, $0.baseAddress, capacity) }
        if count <= 0 { return }
        var offset = 0
        while offset < count {
            let wrote = buffer.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: offset)
                return write(outputFD, base, count - offset)
            }
            if wrote <= 0 { return }
            offset += wrote
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("dorydctl: \(error)\n".utf8))
    exit(1)
}
