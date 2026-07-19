import Foundation

public enum DoryReadinessState: String, Sendable, Codable {
    case waiting
    case ready
    case degraded
    case blocked
    case inactive
}

public enum DoryReadinessStageID: String, CaseIterable, Sendable, Codable {
    case app
    case doryd
    case vmProcess
    case guestAgent
    case mountsDataDisk
    case network
    case dockerd
    case hostSocketContext
    case kubernetes

    public var title: String {
        switch self {
        case .app: "App / control client"
        case .doryd: "doryd control plane"
        case .vmProcess: "VM process"
        case .guestAgent: "Guest agent"
        case .mountsDataDisk: "Mounts and data disk"
        case .network: "Network"
        case .dockerd: "Docker daemon"
        case .hostSocketContext: "Host socket and context"
        case .kubernetes: "Kubernetes"
        }
    }
}

public struct DoryReadinessRepair: Sendable, Equatable, Codable {
    public var owner: String
    public var target: String
    public var mutation: String
    public var automatic: Bool
    public var destructive: Bool

    public init(
        owner: String,
        target: String,
        mutation: String,
        automatic: Bool = false,
        destructive: Bool = false
    ) {
        self.owner = owner
        self.target = target
        self.mutation = mutation
        self.automatic = automatic
        self.destructive = destructive
    }

    var xpcDictionary: NSDictionary {
        [
            "owner": owner,
            "target": target,
            "mutation": mutation,
            "automatic": automatic,
            "destructive": destructive,
        ]
    }
}

public struct DoryReadinessStage: Sendable, Equatable, Codable {
    public var id: DoryReadinessStageID
    public var state: DoryReadinessState
    public var reasonCode: String
    public var detail: String
    public var required: Bool
    public var startedAt: Date?
    public var finishedAt: Date?
    public var deadlineAt: Date?
    public var repair: DoryReadinessRepair

    public init(
        id: DoryReadinessStageID,
        state: DoryReadinessState,
        reasonCode: String,
        detail: String,
        required: Bool = true,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        deadlineAt: Date? = nil,
        repair: DoryReadinessRepair
    ) {
        self.id = id
        self.state = state
        self.reasonCode = reasonCode
        self.detail = detail
        self.required = required
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.deadlineAt = deadlineAt
        self.repair = repair
    }

    public var elapsedMilliseconds: Int? {
        guard let startedAt else { return nil }
        let end = finishedAt ?? Date()
        return max(0, Int((end.timeIntervalSince(startedAt) * 1_000).rounded()))
    }

    public var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id.rawValue,
            "title": id.title,
            "state": state.rawValue,
            "reasonCode": reasonCode,
            "detail": detail,
            "required": required,
            "repair": repair.xpcDictionary,
        ]
        if let startedAt { dictionary["startedAt"] = doryReadinessISO8601(startedAt) }
        if let finishedAt { dictionary["finishedAt"] = doryReadinessISO8601(finishedAt) }
        if let deadlineAt { dictionary["deadlineAt"] = doryReadinessISO8601(deadlineAt) }
        if let elapsedMilliseconds { dictionary["elapsedMilliseconds"] = elapsedMilliseconds }
        return dictionary as NSDictionary
    }
}

public struct DoryReadinessSnapshot: Sendable, Equatable {
    public var cycleID: String
    public var trigger: String
    public var generatedAt: Date
    public var stages: [DoryReadinessStage]

    public init(
        cycleID: String = UUID().uuidString.lowercased(),
        trigger: String,
        generatedAt: Date = Date(),
        stages: [DoryReadinessStage]
    ) {
        self.cycleID = cycleID
        self.trigger = trigger
        self.generatedAt = generatedAt
        self.stages = stages
    }

    public var overall: DoryReadinessState {
        let required = stages.filter(\.required)
        if required.contains(where: { $0.state == .blocked }) { return .blocked }
        if required.contains(where: { $0.state == .waiting }) { return .waiting }
        if required.contains(where: { $0.state == .degraded || $0.state == .inactive }) { return .degraded }
        return .ready
    }

    public var xpcDictionary: NSDictionary {
        [
            "schema": "dev.dory.readiness",
            "version": 1,
            "cycleID": cycleID,
            "trigger": trigger,
            "generatedAt": doryReadinessISO8601(generatedAt),
            "overall": overall.rawValue,
            "stages": stages.map(\.xpcDictionary),
        ]
    }
}

/// Thread-safe startup/wake evidence owned by the Docker lifecycle, not reconstructed from UI state.
/// Health surfaces can add the app, doryd, host-context, and optional Kubernetes stages around this
/// engine-owned core without making `VM process == running` synonymous with Docker readiness.
final class EngineReadinessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var cycleID = UUID().uuidString.lowercased()
    private var trigger = "not-started"
    private var stages: [DoryReadinessStageID: DoryReadinessStage] = [:]
    private var current: DoryReadinessStageID?

    init() {
        for id in Self.engineStageOrder {
            stages[id] = Self.inactiveStage(id, code: "engine.not_started", detail: "Docker engine has not started")
        }
    }

    func beginCycle(trigger: String, at date: Date = Date()) {
        lock.lock()
        cycleID = UUID().uuidString.lowercased()
        self.trigger = trigger
        current = nil
        for id in Self.engineStageOrder {
            stages[id] = Self.waitingStage(id, code: "stage.queued", detail: "Waiting for the previous readiness stage")
        }
        lock.unlock()
        begin(.vmProcess, deadlineSeconds: 120, at: date)
    }

    func begin(_ id: DoryReadinessStageID, deadlineSeconds: TimeInterval, at date: Date = Date()) {
        lock.lock()
        current = id
        stages[id] = DoryReadinessStage(
            id: id,
            state: .waiting,
            reasonCode: "\(id.rawValue).starting",
            detail: "Readiness probe is in progress",
            startedAt: date,
            deadlineAt: date.addingTimeInterval(max(1, deadlineSeconds)),
            repair: Self.repair(for: id)
        )
        lock.unlock()
    }

    func ready(_ id: DoryReadinessStageID, code: String, detail: String, at date: Date = Date()) {
        finish(id, state: .ready, code: code, detail: detail, at: date)
    }

    func degraded(_ id: DoryReadinessStageID, code: String, detail: String, at date: Date = Date()) {
        finish(id, state: .degraded, code: code, detail: detail, at: date)
    }

    func inactive(_ id: DoryReadinessStageID, code: String, detail: String, at date: Date = Date()) {
        finish(id, state: .inactive, code: code, detail: detail, at: date)
    }

    func blocked(_ id: DoryReadinessStageID, code: String, detail: String, at date: Date = Date()) {
        finish(id, state: .blocked, code: code, detail: detail, at: date)
    }

    func blockCurrent(code: String, detail: String, at date: Date = Date()) {
        lock.lock()
        let id = current ?? .vmProcess
        let prior = stages[id]
        stages[id] = DoryReadinessStage(
            id: id,
            state: .blocked,
            reasonCode: code,
            detail: detail,
            startedAt: prior?.startedAt ?? date,
            finishedAt: date,
            deadlineAt: prior?.deadlineAt,
            repair: Self.repair(for: id)
        )
        current = nil
        lock.unlock()
    }

    func markStopped(detail: String, at date: Date = Date()) {
        lock.lock()
        trigger = "stopped"
        current = nil
        for id in Self.engineStageOrder {
            stages[id] = Self.inactiveStage(id, code: "engine.stopped", detail: detail, at: date)
        }
        lock.unlock()
    }

    func snapshot(now: Date = Date()) -> DoryReadinessSnapshot {
        lock.lock()
        let snapshot = DoryReadinessSnapshot(
            cycleID: cycleID,
            trigger: trigger,
            generatedAt: now,
            stages: Self.engineStageOrder.compactMap { stages[$0] }
        )
        lock.unlock()
        return snapshot
    }

    private func finish(
        _ id: DoryReadinessStageID,
        state: DoryReadinessState,
        code: String,
        detail: String,
        at date: Date
    ) {
        lock.lock()
        let prior = stages[id]
        stages[id] = DoryReadinessStage(
            id: id,
            state: state,
            reasonCode: code,
            detail: detail,
            required: prior?.required ?? true,
            startedAt: prior?.startedAt ?? date,
            finishedAt: date,
            deadlineAt: prior?.deadlineAt,
            repair: Self.repair(for: id)
        )
        if current == id { current = nil }
        lock.unlock()
    }

    static let engineStageOrder: [DoryReadinessStageID] = [
        .vmProcess, .guestAgent, .mountsDataDisk, .network, .dockerd, .hostSocketContext,
    ]

    static func repair(for id: DoryReadinessStageID) -> DoryReadinessRepair {
        switch id {
        case .app:
            DoryReadinessRepair(owner: "Dory.app", target: "app", mutation: "Reconnect the app to the authenticated doryd endpoint")
        case .doryd:
            DoryReadinessRepair(owner: "launchd", target: "doryd", mutation: "Reload only the per-user doryd LaunchAgent")
        case .vmProcess:
            DoryReadinessRepair(owner: "doryd", target: "vm-process", mutation: "Restart the failed VM helper against the same verified data drive", automatic: true)
        case .guestAgent:
            DoryReadinessRepair(owner: "doryd", target: "guest-agent", mutation: "Drop the stale RPC channel and reconnect to the existing guest agent")
        case .mountsDataDisk:
            DoryReadinessRepair(owner: "doryd", target: "data-drive", mutation: "Revalidate the selected drive identity and remount it without formatting")
        case .network:
            DoryReadinessRepair(owner: "doryd networking reconciler", target: "routes", mutation: "Re-derive and reapply only Dory-owned DNS routes and forwards")
        case .dockerd:
            DoryReadinessRepair(owner: "doryd guest control", target: "dockerd", mutation: "Restart dockerd in the existing VM only after the API is confirmed failed")
        case .hostSocketContext:
            DoryReadinessRepair(owner: "doryd / host CLI installer", target: "socket", mutation: "Replace the stale forwarder socket, then repoint the dory Docker context")
        case .kubernetes:
            DoryReadinessRepair(owner: "Dory Kubernetes provider", target: "kubernetes", mutation: "Restart or reconnect the existing k3s control plane without deleting its volumes")
        }
    }

    private static func waitingStage(
        _ id: DoryReadinessStageID,
        code: String,
        detail: String
    ) -> DoryReadinessStage {
        DoryReadinessStage(
            id: id,
            state: .waiting,
            reasonCode: code,
            detail: detail,
            repair: repair(for: id)
        )
    }

    private static func inactiveStage(
        _ id: DoryReadinessStageID,
        code: String,
        detail: String,
        at date: Date? = nil
    ) -> DoryReadinessStage {
        DoryReadinessStage(
            id: id,
            state: .inactive,
            reasonCode: code,
            detail: detail,
            required: false,
            startedAt: date,
            finishedAt: date,
            repair: repair(for: id)
        )
    }
}

private func doryReadinessISO8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
