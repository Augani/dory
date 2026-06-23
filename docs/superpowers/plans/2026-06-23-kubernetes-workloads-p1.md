# Kubernetes Workload Surface — P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Dory's thin read-only pods table into a credible cluster browser — Pods / Deployments / Services with a namespace + resource-kind switcher, pod logs (follow + copy), pod delete, and a kubeconfig hint.

**Architecture:** Keep the existing `kubectl` shell-out transport (zero new deps, free streaming logs) behind one new pure `KubeClient` seam that owns argv construction. All JSON→row mapping, log parsing, and the kubeconfig hint are pure functions unit-tested without a cluster. The SwiftUI surfaces reuse the established design-system primitives (`TableHeader`, `tableRow()`, `StatusBadge`) and the `ImagesView` `confirmationDialog`+`pending<Item>` mutation pattern; pod logs reuse the `ContainerDetailView` `ScrollViewReader` auto-scroll + `ContainerStatsFormat.logsPlainText` copy block verbatim.

**Tech Stack:** Swift 6 / SwiftUI, `@Observable` `AppStore`, the `Testing` framework (`@Test`/`#expect`, `@testable import Dory`), `Foundation.Process` via the existing `Shell` helper.

## Global Constraints

- **No line comments; no docstrings except on public-API functions that need them.** (repo CLAUDE.md)
- **Functional SwiftUI:** no ViewModels; `@Environment(AppStore.self)` + `@Environment(\.palette)`; views are pure state expressions.
- **Transport is `kubectl` shell-out only.** No direct API-server HTTP client this cycle (design spec, "Access strategy decision").
- **kubectl resolution:** `Shell.find("kubectl", candidates: ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"])`. Absence is surfaced honestly, never crashed.
- **kubeconfig:** prefer `KubernetesProvisioner.kubeconfigPath` (`~/.kube/dory-config`) when it exists; never mutate `~/.kube/config`.
- **No destructive action without a `confirmationDialog`** stating "This cannot be undone." (WS5 actions-parity rule).
- **Build toolchain:** all builds/tests go through `scripts/build.sh` / `scripts/test.sh` (they export the Xcode 27 beta `DEVELOPER_DIR`). Ignore SourceKit false-positive errors in-editor; the script's `BUILD SUCCEEDED` + `xcodebuild_exit=0` is ground truth.
- **Spec:** `docs/superpowers/specs/2026-06-23-kubernetes-workloads-design.md` (Phase 1). P2 (exec + scale/restart) and P3 (configmaps/secrets/ingress) are separate plans.

---

## File Structure

| File | Responsibility |
|---|---|
| `Dory/Runtime/Kubernetes/KubeClient.swift` (new) | Pure argv (`args`, `deleteArgs`) + `KubeError` + `getJSON`/`delete` transport |
| `Dory/Runtime/Kubernetes/KubeModels.swift` (new) | `Decodable` API structs + row structs (`KubeDeploymentRow`, `KubeServiceRow`) + `KubeRowMapper` |
| `Dory/Runtime/Kubernetes/KubeLogParser.swift` (new) | Pure `--timestamps` line → `[LogLine]` |
| `Dory/Runtime/Kubernetes/KubeContextHint.swift` (new) | Pure `export KUBECONFIG=…` snippet |
| `Dory/Models/Models.swift` (modify) | Add `KubeResourceKind` enum |
| `Dory/Runtime/Kubernetes/KubernetesProvider.swift` (modify) | Refactor `status()` onto `KubeClient` + `KubeRowMapper.pods` (no behavior change) |
| `Dory/Models/AppStore.swift` (modify) | Kube state, `loadKubernetes()` expansion, `deletePod`, `podLogs`, `streamPodLogs`, `kubeconfigHint`, `selectedPodID` |
| `Dory/Features/Tables/KubernetesView.swift` (modify) | Namespace `Picker` + kind switcher + per-kind tables + pod hover-delete + "Use in kubectl" menu |
| `Dory/Features/Tables/PodDetailView.swift` (new) | Pod overview + logs tab (reuses container logs block) |
| `Dory/Runtime/MockData.swift` (modify) | Mock deployments/services so snapshots render without a cluster |
| `DoryTests/KubeClientArgsTests.swift`, `KubeRowMapperTests.swift`, `KubeLogParserTests.swift`, `KubeContextHintTests.swift` (new) | Pure-logic unit tests |

---

## Task 1: KubeClient transport seam

**Files:**
- Create: `Dory/Runtime/Kubernetes/KubeClient.swift`
- Test: `DoryTests/KubeClientArgsTests.swift`

**Interfaces:**
- Consumes: `Shell.find`, `Shell.runAsyncResult(_:_:) async -> (output: String, exit: Int32)`, `KubernetesProvisioner.kubeconfigPath`.
- Produces: `KubeClient` with `static func args(kind:namespace:kubeconfig:) -> [String]`, `static func deleteArgs(kind:name:namespace:kubeconfig:) -> [String]`, `func getJSON(kind:namespace:) async -> Result<Data, KubeError>`, `func delete(kind:name:namespace:) async -> Result<Void, KubeError>`, `static func kubeconfig() -> String?`, `var kubectlPath: String?`. `enum KubeError: Error, Sendable, Equatable { case kubectlMissing; case nonZero(Int32, String); case decode }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Dory

struct KubeClientArgsTests {
    @Test func allNamespacesUsesAllFlag() {
        #expect(KubeClient.args(kind: "pods", namespace: nil, kubeconfig: "/k")
            == ["--kubeconfig", "/k", "get", "pods", "-A", "-o", "json"])
    }

    @Test func concreteNamespaceScopes() {
        #expect(KubeClient.args(kind: "pods", namespace: "kube-system", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "get", "pods", "-n", "kube-system", "-o", "json"])
    }

    @Test func missingKubeconfigOmitsFlag() {
        #expect(KubeClient.args(kind: "deployments", namespace: nil, kubeconfig: nil)
            == ["get", "deployments", "-A", "-o", "json"])
    }

    @Test func deleteArgsScopeToNamespace() {
        #expect(KubeClient.deleteArgs(kind: "pod", name: "web-1", namespace: "default", kubeconfig: "/k")
            == ["--kubeconfig", "/k", "delete", "pod", "web-1", "-n", "default"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubeClientArgsTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'KubeClient' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum KubeError: Error, Sendable, Equatable {
    case kubectlMissing
    case nonZero(Int32, String)
    case decode
}

struct KubeClient: Sendable {
    var kubectlPath: String? {
        Shell.find("kubectl", candidates: ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"])
    }

    static func kubeconfig() -> String? {
        let path = KubernetesProvisioner.kubeconfigPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func args(kind: String, namespace: String?, kubeconfig: String?) -> [String] {
        var args: [String] = []
        if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
        args += ["get", kind]
        if let namespace, !namespace.isEmpty { args += ["-n", namespace] } else { args += ["-A"] }
        args += ["-o", "json"]
        return args
    }

    static func deleteArgs(kind: String, name: String, namespace: String, kubeconfig: String?) -> [String] {
        var args: [String] = []
        if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
        args += ["delete", kind, name, "-n", namespace]
        return args
    }

    func getJSON(kind: String, namespace: String?) async -> Result<Data, KubeError> {
        guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
        let result = await Shell.runAsyncResult(kubectl, Self.args(kind: kind, namespace: namespace, kubeconfig: Self.kubeconfig()))
        guard result.exit == 0 else { return .failure(.nonZero(result.exit, result.output)) }
        guard let data = result.output.data(using: .utf8) else { return .failure(.decode) }
        return .success(data)
    }

    func delete(kind: String, name: String, namespace: String) async -> Result<Void, KubeError> {
        guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
        let result = await Shell.runAsyncResult(kubectl, Self.deleteArgs(kind: kind, name: name, namespace: namespace, kubeconfig: Self.kubeconfig()))
        return result.exit == 0 ? .success(()) : .failure(.nonZero(result.exit, result.output))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/KubeClientArgsTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubeClient.swift DoryTests/KubeClientArgsTests.swift
git commit -m "feat(k8s): KubeClient transport seam with pure argv builders"
```

---

## Task 2: Kube row models + mappers

**Files:**
- Create: `Dory/Runtime/Kubernetes/KubeModels.swift`
- Test: `DoryTests/KubeRowMapperTests.swift`

**Interfaces:**
- Consumes: existing `Pod`, `PodPhase`, `KubeMetadata`, `KubePodList`, `KubeContainerStatus` (in `KubernetesProvider.swift`), `DockerFormat.relative(iso:)`.
- Produces: `KubeDeploymentRow`, `KubeServiceRow` row structs; `KubeDeploymentList`, `KubeServiceList`, `KubeNamespaceList` decodables; `enum KubeRowMapper` with `static func pods(_:) -> [Pod]`, `deployments(_:) -> [KubeDeploymentRow]`, `services(_:) -> [KubeServiceRow]`, `namespaces(_:) -> [String]`, and `static func podPhase(_:statuses:) -> PodPhase`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Dory

struct KubeRowMapperTests {
    private func decode<T: Decodable>(_ json: String, as type: T.Type) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func deploymentReadyRatio() {
        let list = decode(#"{"items":[{"metadata":{"name":"web","namespace":"default","creationTimestamp":null},"spec":{"replicas":3},"status":{"readyReplicas":2,"availableReplicas":2,"updatedReplicas":3}}]}"#, as: KubeDeploymentList.self)
        let rows = KubeRowMapper.deployments(list)
        #expect(rows.count == 1)
        #expect(rows[0].name == "web")
        #expect(rows[0].ready == "2/3")
        #expect(rows[0].available == 2)
    }

    @Test func servicesSkipHeadless() {
        let list = decode(#"{"items":[{"metadata":{"name":"db","namespace":"data"},"spec":{"type":"ClusterIP","clusterIP":"None","ports":[{"port":5432,"protocol":"TCP"}]}},{"metadata":{"name":"web","namespace":"default"},"spec":{"type":"ClusterIP","clusterIP":"10.0.0.5","ports":[{"port":80,"protocol":"TCP"},{"port":443,"protocol":"TCP"}]}}]}"#, as: KubeServiceList.self)
        let rows = KubeRowMapper.services(list)
        #expect(rows.count == 1)
        #expect(rows[0].name == "web")
        #expect(rows[0].ports == "80/TCP, 443/TCP")
    }

    @Test func podsReproduceExistingMapping() {
        let list = decode(#"{"items":[{"metadata":{"name":"web-1","namespace":"default"},"status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":2}]}}]}"#, as: KubePodList.self)
        let rows = KubeRowMapper.pods(list)
        #expect(rows.count == 1)
        #expect(rows[0].ready == "1/1")
        #expect(rows[0].restarts == 2)
        #expect(rows[0].phase == .running)
    }

    @Test func namespacesExtractNames() {
        let list = decode(#"{"items":[{"metadata":{"name":"default"}},{"metadata":{"name":"kube-system"}}]}"#, as: KubeNamespaceList.self)
        #expect(KubeRowMapper.namespaces(list) == ["default", "kube-system"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubeRowMapperTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'KubeDeploymentList'` / `KubeRowMapper`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct KubeDeploymentSpec: Decodable, Sendable { var replicas: Int? }
struct KubeDeploymentStatus: Decodable, Sendable {
    var readyReplicas: Int?
    var availableReplicas: Int?
    var updatedReplicas: Int?
}
struct KubeDeployment: Decodable, Sendable {
    var metadata: KubeMetadata?
    var spec: KubeDeploymentSpec?
    var status: KubeDeploymentStatus?
}
struct KubeDeploymentList: Decodable, Sendable { var items: [KubeDeployment]? }

struct KubeServicePort: Decodable, Sendable {
    var port: Int?
    var nodePort: Int?
    var `protocol`: String?
}
struct KubeServiceSpec: Decodable, Sendable {
    var type: String?
    var clusterIP: String?
    var ports: [KubeServicePort]?
}
struct KubeService: Decodable, Sendable {
    var metadata: KubeMetadata?
    var spec: KubeServiceSpec?
}
struct KubeServiceList: Decodable, Sendable { var items: [KubeService]? }

struct KubeNamespaceItem: Decodable, Sendable { var metadata: KubeMetadata? }
struct KubeNamespaceList: Decodable, Sendable { var items: [KubeNamespaceItem]? }

struct KubeDeploymentRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var ready: String
    var upToDate: Int
    var available: Int
    var age: String
    var id: String { "\(namespace)/\(name)" }
}

struct KubeServiceRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var type: String
    var clusterIP: String
    var ports: String
    var age: String
    var id: String { "\(namespace)/\(name)" }
}

enum KubeRowMapper {
    static func podPhase(_ phase: String?, statuses: [KubeContainerStatus]) -> PodPhase {
        switch phase {
        case "Running": return .running
        case "Pending": return .pending
        case "Succeeded": return .completed
        default: return .crashLoopBackOff
        }
    }

    static func pods(_ list: KubePodList) -> [Pod] {
        (list.items ?? []).compactMap { pod in
            guard let name = pod.metadata?.name else { return nil }
            let statuses = pod.status?.containerStatuses ?? []
            let ready = statuses.filter { $0.ready == true }.count
            let restarts = statuses.reduce(0) { $0 + ($1.restartCount ?? 0) }
            return Pod(
                name: name, namespace: pod.metadata?.namespace ?? "default",
                phase: podPhase(pod.status?.phase, statuses: statuses),
                ready: "\(ready)/\(max(statuses.count, 1))", restarts: restarts,
                age: DockerFormat.relative(iso: pod.metadata?.creationTimestamp)
            )
        }
    }

    static func deployments(_ list: KubeDeploymentList) -> [KubeDeploymentRow] {
        (list.items ?? []).compactMap { dep in
            guard let name = dep.metadata?.name else { return nil }
            let desired = dep.spec?.replicas ?? 0
            let ready = dep.status?.readyReplicas ?? 0
            return KubeDeploymentRow(
                name: name, namespace: dep.metadata?.namespace ?? "default",
                ready: "\(ready)/\(desired)", upToDate: dep.status?.updatedReplicas ?? 0,
                available: dep.status?.availableReplicas ?? 0,
                age: DockerFormat.relative(iso: dep.metadata?.creationTimestamp)
            )
        }
    }

    static func services(_ list: KubeServiceList) -> [KubeServiceRow] {
        (list.items ?? []).compactMap { svc in
            guard let name = svc.metadata?.name else { return nil }
            let clusterIP = svc.spec?.clusterIP ?? ""
            guard clusterIP != "None" else { return nil }
            let ports = (svc.spec?.ports ?? []).map { port in
                "\(port.port ?? 0)/\(port.protocol ?? "TCP")"
            }.joined(separator: ", ")
            return KubeServiceRow(
                name: name, namespace: svc.metadata?.namespace ?? "default",
                type: svc.spec?.type ?? "ClusterIP", clusterIP: clusterIP, ports: ports,
                age: DockerFormat.relative(iso: svc.metadata?.creationTimestamp)
            )
        }
    }

    static func namespaces(_ list: KubeNamespaceList) -> [String] {
        (list.items ?? []).compactMap { $0.metadata?.name }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/KubeRowMapperTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubeModels.swift DoryTests/KubeRowMapperTests.swift
git commit -m "feat(k8s): deployment/service/namespace models + pure KubeRowMapper"
```

---

## Task 3: KubeResourceKind enum

**Files:**
- Modify: `Dory/Models/Models.swift` (add enum after `PodPhase`, around line 149)

**Interfaces:**
- Produces: `enum KubeResourceKind: String, CaseIterable, Identifiable, Sendable { case pods, deployments, services }` with `var id: String`, `var label: String`, `var apiKind: String`.

- [ ] **Step 1: Write the failing test**

Add to a new file `DoryTests/KubeResourceKindTests.swift`:

```swift
import Testing
@testable import Dory

struct KubeResourceKindTests {
    @Test func apiKindMatchesKubectl() {
        #expect(KubeResourceKind.pods.apiKind == "pods")
        #expect(KubeResourceKind.deployments.apiKind == "deployments")
        #expect(KubeResourceKind.services.apiKind == "services")
    }
    @Test func labelsAreTitleCased() {
        #expect(KubeResourceKind.pods.label == "Pods")
        #expect(KubeResourceKind.services.label == "Services")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubeResourceKindTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'KubeResourceKind'`.

- [ ] **Step 3: Write minimal implementation**

Insert after the `PodPhase` enum closing brace (Models.swift:149):

```swift
enum KubeResourceKind: String, CaseIterable, Identifiable, Sendable {
    case pods, deployments, services
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pods: "Pods"
        case .deployments: "Deployments"
        case .services: "Services"
        }
    }
    var apiKind: String { rawValue }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/KubeResourceKindTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Models/Models.swift DoryTests/KubeResourceKindTests.swift
git commit -m "feat(k8s): KubeResourceKind enum for the resource switcher"
```

---

## Task 4: KubeLogParser

**Files:**
- Create: `Dory/Runtime/Kubernetes/KubeLogParser.swift`
- Test: `DoryTests/KubeLogParserTests.swift`

**Interfaces:**
- Consumes: existing `LogLine`, `LogLevel`.
- Produces: `enum KubeLogParser` with `static func parse(_ raw: String) -> [LogLine]` and `static func level(for message: String) -> LogLevel`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Dory

struct KubeLogParserTests {
    @Test func timestampSplit() {
        let lines = KubeLogParser.parse("2026-06-23T10:00:00Z hello world")
        #expect(lines.count == 1)
        #expect(lines[0].timestamp == "2026-06-23T10:00:00Z")
        #expect(lines[0].message == "hello world")
    }
    @Test func errorLevelInferred() {
        #expect(KubeLogParser.parse("2026-06-23T10:00:00Z ERROR boom")[0].level == .error)
    }
    @Test func plainLineHasEmptyTimestamp() {
        let lines = KubeLogParser.parse("just a message")
        #expect(lines[0].timestamp == "")
        #expect(lines[0].message == "just a message")
    }
    @Test func emptyInput() {
        #expect(KubeLogParser.parse("").isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubeLogParserTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'KubeLogParser'`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum KubeLogParser {
    static func parse(_ raw: String) -> [LogLine] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).map { slice in
            let line = String(slice)
            if let space = line.firstIndex(of: " ") {
                let prefix = line[line.startIndex..<space]
                if prefix.contains("T") && prefix.contains(":") {
                    let message = String(line[line.index(after: space)...])
                    return LogLine(timestamp: String(prefix), level: level(for: message), message: message)
                }
            }
            return LogLine(timestamp: "", level: level(for: line), message: line)
        }
    }

    static func level(for message: String) -> LogLevel {
        let upper = message.uppercased()
        if upper.contains("ERROR") || upper.contains("FATAL") { return .error }
        if upper.contains("WARN") { return .warn }
        if upper.contains("DEBUG") { return .debug }
        return .info
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/KubeLogParserTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubeLogParser.swift DoryTests/KubeLogParserTests.swift
git commit -m "feat(k8s): pure KubeLogParser for --timestamps pod logs"
```

---

## Task 5: KubeContextHint

**Files:**
- Create: `Dory/Runtime/Kubernetes/KubeContextHint.swift`
- Test: `DoryTests/KubeContextHintTests.swift`

**Interfaces:**
- Produces: `enum KubeContextHint` with `static func snippet(kubeconfigPath: String) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Dory

struct KubeContextHintTests {
    @Test func snippetContainsExportAndPath() {
        let snippet = KubeContextHint.snippet(kubeconfigPath: "/Users/x/.kube/dory-config")
        #expect(snippet.contains("export KUBECONFIG=/Users/x/.kube/dory-config"))
        #expect(snippet.contains("kubectl get pods"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubeContextHintTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'KubeContextHint'`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum KubeContextHint {
    static func snippet(kubeconfigPath: String) -> String {
        """
        export KUBECONFIG=\(kubeconfigPath)
        kubectl get pods -A
        """
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/KubeContextHintTests 2>&1 | tail -20`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubeContextHint.swift DoryTests/KubeContextHintTests.swift
git commit -m "feat(k8s): KubeContextHint kubeconfig snippet"
```

---

## Task 6: Refactor KubernetesProvider onto KubeClient + KubeRowMapper

**Files:**
- Modify: `Dory/Runtime/Kubernetes/KubernetesProvider.swift`

**Interfaces:**
- Consumes: `KubeClient.kubeconfig()`, `KubeRowMapper.pods`.
- Produces: unchanged `KubernetesProvider.status() async -> KubernetesStatus` (behavior identical; pod mapping now delegates to `KubeRowMapper.pods`). Remove the now-duplicated `private func pods(kubectl:)` and `static func phase(...)` — `KubeRowMapper` owns them. Keep `KubeVersion`, `KubeNode`, `KubernetesStatus`, `decode`, `kubectlPath`, `kubeconfigArgs`.

This is a pure refactor gated by the `KubeRowMapperTests.podsReproduceExistingMapping` regression test (Task 2) plus a full build.

- [ ] **Step 1: Replace the pod mapping call**

In `status()`, replace `let pods = await pods(kubectl: kubectl)` with:

```swift
let pods = await decode(kubectl, kubeconfigArgs + ["get", "pods", "-A", "-o", "json"], as: KubePodList.self).map(KubeRowMapper.pods) ?? []
```

- [ ] **Step 2: Delete the duplicated helpers**

Remove the `private func pods(kubectl:)` method (lines ~71-85) and the `static func phase(_:statuses:)` method (lines ~93-100) — `KubeRowMapper.pods` / `KubeRowMapper.podPhase` replace them.

- [ ] **Step 3: Build + regression test**

Run: `scripts/build.sh 2>&1 | tail -5` → Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.
Run: `scripts/test.sh -only-testing:DoryTests/KubeRowMapperTests 2>&1 | tail -10` → Expected: PASS (pod mapping unchanged).

- [ ] **Step 4: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubernetesProvider.swift
git commit -m "refactor(k8s): KubernetesProvider pod mapping delegates to KubeRowMapper"
```

---

## Task 7: AppStore kube state, loads, mutations, logs

**Files:**
- Modify: `Dory/Models/AppStore.swift`

**Interfaces:**
- Consumes: `KubeClient`, `KubeRowMapper`, `KubeLogParser`, `KubeContextHint`, `KubernetesProvisioner.kubeconfigPath`, existing `actionError`, the `buildImage` `AsyncStream`-over-`Process` idiom (AppStore.swift:925) and the `applyKubernetesYAML` drained-pipe idiom (AppStore.swift:952).
- Produces on `AppStore`: `var kubeNamespace = "All Namespaces"`, `var kubeResource: KubeResourceKind = .pods`, `var kubeNamespaces: [String] = []`, `var deployments: [KubeDeploymentRow] = []`, `var kubeServices: [KubeServiceRow] = []`, `var selectedPodID: String? = nil`; expanded `func loadKubernetes() async`; `func deletePod(_ pod: Pod) async`; `func podLogs(_ pod: Pod) async -> [LogLine]`; `func streamPodLogs(_ pod: Pod) -> AsyncStream<LogLine>`; `var kubeconfigHint: String`; helper `private var kubeClient = KubeClient()`; `func selectedPod() -> Pod?`. Sentinel: `kubeNamespace == "All Namespaces"` maps to `nil` (→ `-A`).

- [ ] **Step 1: Add state + the client**

After `private let kubernetes = KubernetesProvider()` (AppStore.swift:76) add:

```swift
private let kubeClient = KubeClient()
var kubeNamespace = "All Namespaces"
var kubeResource: KubeResourceKind = .pods
var kubeNamespaces: [String] = []
var deployments: [KubeDeploymentRow] = []
var kubeServices: [KubeServiceRow] = []
var selectedPodID: String? = nil

private var namespaceFilter: String? { kubeNamespace == "All Namespaces" ? nil : kubeNamespace }
var kubeconfigHint: String { KubeContextHint.snippet(kubeconfigPath: KubernetesProvisioner.kubeconfigPath) }
func selectedPod() -> Pod? { pods.first { $0.id == selectedPodID } }
```

- [ ] **Step 2: Expand `loadKubernetes()`**

Replace the existing `loadKubernetes()` (AppStore.swift:432-438) with:

```swift
func loadKubernetes() async {
    guard runtimeKind != .mock else { kubernetesReachable = false; return }
    let status = await kubernetes.status()
    kubernetesReachable = status.reachable
    kubernetesInfo = status.info
    guard status.reachable else { pods = []; deployments = []; kubeServices = []; kubeNamespaces = []; return }
    if case let .success(data) = await kubeClient.getJSON(kind: "namespaces", namespace: nil),
       let list = try? JSONDecoder().decode(KubeNamespaceList.self, from: data) {
        kubeNamespaces = KubeRowMapper.namespaces(list)
    }
    await loadKubeResource()
}

func loadKubeResource() async {
    guard kubernetesReachable else { return }
    switch kubeResource {
    case .pods:
        if case let .success(data) = await kubeClient.getJSON(kind: "pods", namespace: namespaceFilter),
           let list = try? JSONDecoder().decode(KubePodList.self, from: data) {
            pods = KubeRowMapper.pods(list)
        }
    case .deployments:
        if case let .success(data) = await kubeClient.getJSON(kind: "deployments", namespace: namespaceFilter),
           let list = try? JSONDecoder().decode(KubeDeploymentList.self, from: data) {
            deployments = KubeRowMapper.deployments(list)
        }
    case .services:
        if case let .success(data) = await kubeClient.getJSON(kind: "services", namespace: namespaceFilter),
           let list = try? JSONDecoder().decode(KubeServiceList.self, from: data) {
            kubeServices = KubeRowMapper.services(list)
        }
    }
}
```

- [ ] **Step 3: Add pod delete (confirmed by the view) + logs**

Add near `loadKubernetes`:

```swift
func deletePod(_ pod: Pod) async {
    switch await kubeClient.delete(kind: "pod", name: pod.name, namespace: pod.namespace) {
    case .success: await loadKubeResource()
    case .failure(let error): actionError = Self.kubeErrorText(error)
    }
}

func podLogs(_ pod: Pod) async -> [LogLine] {
    guard let kubectl = kubeClient.kubectlPath else { return [] }
    var args: [String] = []
    if let kubeconfig = KubeClient.kubeconfig() { args += ["--kubeconfig", kubeconfig] }
    args += ["logs", pod.name, "-n", pod.namespace, "--tail=200", "--timestamps"]
    let result = await Shell.runAsyncResult(kubectl, args)
    guard result.exit == 0 else { return [] }
    return KubeLogParser.parse(result.output)
}

func streamPodLogs(_ pod: Pod) -> AsyncStream<LogLine> {
    AsyncStream { cont in
        guard let kubectl = kubeClient.kubectlPath else { cont.finish(); return }
        var args: [String] = []
        if let kubeconfig = KubeClient.kubeconfig() { args += ["--kubeconfig", kubeconfig] }
        args += ["logs", pod.name, "-n", pod.namespace, "-f", "--since=1s", "--timestamps"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: kubectl)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            for line in KubeLogParser.parse(text) { cont.yield(line) }
        }
        process.terminationHandler = { _ in
            handle.readabilityHandler = nil
            cont.finish()
        }
        cont.onTermination = { _ in
            handle.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        do { try process.run() } catch { cont.finish() }
    }
}

static func kubeErrorText(_ error: KubeError) -> String {
    switch error {
    case .kubectlMissing: "kubectl not found — install it (brew install kubectl)."
    case .nonZero(_, let stderr): stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    case .decode: "Could not read the cluster response."
    }
}
```

- [ ] **Step 4: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Dory/Models/AppStore.swift
git commit -m "feat(k8s): AppStore kube state, namespace/kind loads, pod delete + logs streaming"
```

---

## Task 8: KubernetesView — namespace + kind switcher, per-kind tables, pod delete, kubeconfig hint

**Files:**
- Modify: `Dory/Features/Tables/KubernetesView.swift`

**Interfaces:**
- Consumes: `store.kubeNamespace`, `store.kubeNamespaces`, `store.kubeResource`, `store.deployments`, `store.kubeServices`, `store.pods`, `store.deletePod`, `store.loadKubeResource`, `store.kubeconfigHint`, `store.selectedPodID`; design-system `TableHeader`, `tableRow()`, `StatusBadge`, `IconButton`.
- Produces: a redesigned `podList` (rename to `clusterBrowser`) whose body switches on `store.kubeResource`; the namespace `Picker` + kind `Picker(.segmented)` live in the existing `banner`.

- [ ] **Step 1: Add the switcher controls to `banner`**

In `banner`, after the `Text(bannerInfo)` line and before `Spacer(minLength: 0)`, insert:

```swift
Picker("", selection: Binding(get: { store.kubeResource }, set: { store.kubeResource = $0; Task { await store.loadKubeResource() } })) {
    ForEach(KubeResourceKind.allCases) { kind in Text(kind.label).tag(kind) }
}
.pickerStyle(.segmented).fixedSize().labelsHidden()
Picker("", selection: Binding(get: { store.kubeNamespace }, set: { store.kubeNamespace = $0; Task { await store.loadKubeResource() } })) {
    Text("All Namespaces").tag("All Namespaces")
    ForEach(store.kubeNamespaces, id: \.self) { ns in Text(ns).tag(ns) }
}
.pickerStyle(.menu).fixedSize().labelsHidden()
```

- [ ] **Step 2: Add the "Use in kubectl" menu item**

In the `Menu { … }` of `banner`, after `Button("Apply YAML…")` and its `Divider()`, add:

```swift
Button("Copy kubeconfig for kubectl") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(store.kubeconfigHint, forType: .string)
}
Divider()
```

- [ ] **Step 3: Switch the body on resource kind**

Replace the `TableHeader(...) + ScrollView { LazyVStack { ForEach(store.pods) … } }` block inside `podList` with a `@ViewBuilder` that switches:

```swift
switch store.kubeResource {
case .pods: podTable
case .deployments: deploymentTable
case .services: serviceTable
}
```

Add `podTable` (the existing pod columns + a hover trash that sets `pendingDeletePod`, and double-tap setting `store.selectedPodID`), `deploymentTable` (columns `DEPLOYMENT`, `NAMESPACE`, `READY`, `UP-TO-DATE`, `AVAILABLE`, `AGE`), and `serviceTable` (columns `SERVICE`, `NAMESPACE`, `TYPE`, `CLUSTER-IP`, `PORTS`, `AGE`), each built with `TableHeader` + `tableRow()` mirroring the existing pod row. Add `@State private var pendingDeletePod: Pod?` and a `.confirmationDialog` on the pod row:

```swift
.confirmationDialog(
    "Delete pod \(pendingDeletePod?.name ?? "")?",
    isPresented: Binding(get: { pendingDeletePod != nil }, set: { if !$0 { pendingDeletePod = nil } }),
    titleVisibility: .visible
) {
    Button("Delete", role: .destructive) { if let pod = pendingDeletePod { Task { await store.deletePod(pod) } } }
    Button("Cancel", role: .cancel) {}
} message: { Text("This permanently removes the pod. This cannot be undone.") }
```

> Keep the empty-state gate: show `emptyState` only when the cluster is unreachable, not merely when `store.pods` is empty (deployments/services can be non-empty with zero pods). Change `body` to `if !store.kubernetesReachable && store.pods.isEmpty { emptyState } else { podList }`.

- [ ] **Step 4: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Dory/Features/Tables/KubernetesView.swift
git commit -m "feat(k8s): cluster browser — namespace/kind switcher, deployments/services tables, pod delete"
```

---

## Task 9: PodDetailView — logs tab

**Files:**
- Create: `Dory/Features/Tables/PodDetailView.swift`

**Interfaces:**
- Consumes: `store.selectedPod()`, `store.podLogs`, `store.streamPodLogs`, `store.selectedPodID`, `ContainerStatsFormat.logsPlainText`, the `ContainerDetailView` logs block (ScrollViewReader auto-scroll, `id: "logs-cursor"` cursor, Copy button, 200-line cap) as the template.
- Produces: `struct PodDetailView: View` presented when `store.selectedPodID != nil` (wire it as an overlay/sheet from `KubernetesView`, or a navigation detail consistent with how `ContainerDetailView` is presented — follow the existing container-detail presentation).

- [ ] **Step 1: Implement the view (mirror the container logs block)**

```swift
import SwiftUI

struct PodDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let pod: Pod
    @State private var logLines: [LogLine] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            logs
        }
        .task(id: pod.id) {
            logLines = await store.podLogs(pod)
            for await line in store.streamPodLogs(pod) {
                logLines.append(line)
                if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(label: pod.phase.rawValue, color: pod.phase.color(p), background: pod.phase.background(p))
            Text(pod.name).font(.mono(14, weight: .semibold)).foregroundStyle(p.text)
            Text(pod.namespace).font(.system(size: 12)).foregroundStyle(p.text3)
            Spacer()
            Button("Done") { store.selectedPodID = nil }.buttonStyle(.plain).foregroundStyle(p.accentText)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ContainerStatsFormat.logsPlainText(logLines), forType: .string)
                } label: { Text("Copy").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).disabled(logLines.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logLines) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.timestamp).font(.mono(11)).foregroundStyle(p.text3)
                                Text(line.message).font(.mono(12)).foregroundStyle(line.level.color(p))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Color.clear.frame(height: 1).id("logs-cursor")
                    }
                    .padding(12)
                }
                .onChange(of: logLines.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("logs-cursor", anchor: .bottom) }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Present it from KubernetesView**

In `KubernetesView.podList`, overlay the detail when a pod is selected:

```swift
.overlay {
    if let pod = store.selectedPod() {
        PodDetailView(pod: pod).background(p.bg).transition(.move(edge: .trailing))
    }
}
```

- [ ] **Step 3: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 4: Commit**

```bash
git add Dory/Features/Tables/PodDetailView.swift Dory/Features/Tables/KubernetesView.swift
git commit -m "feat(k8s): PodDetailView with auto-scrolling, copyable pod logs"
```

---

## Task 10: MockData deployments + services

**Files:**
- Modify: `Dory/Runtime/MockData.swift`

**Interfaces:**
- Produces: `static let deployments: [KubeDeploymentRow]` and `static let kubeServices: [KubeServiceRow]` on `MockData`, so the mock backend renders the new tables in snapshots without a live cluster. Wire them into `AppStore` so that under `runtimeKind == .mock` the new tables populate (mirror how `MockData.pods` reaches `store.pods`).

- [ ] **Step 1: Add mock rows**

After `MockData.pods` (MockData.swift:38-45) add:

```swift
static let deployments: [KubeDeploymentRow] = [
    KubeDeploymentRow(name: "web", namespace: "default", ready: "2/2", upToDate: 2, available: 2, age: "42m"),
    KubeDeploymentRow(name: "redis", namespace: "cache", ready: "1/1", upToDate: 1, available: 1, age: "2h"),
    KubeDeploymentRow(name: "worker", namespace: "jobs", ready: "0/1", upToDate: 1, available: 0, age: "5m"),
]

static let kubeServices: [KubeServiceRow] = [
    KubeServiceRow(name: "web", namespace: "default", type: "ClusterIP", clusterIP: "10.43.0.12", ports: "80/TCP", age: "42m"),
    KubeServiceRow(name: "redis", namespace: "cache", type: "ClusterIP", clusterIP: "10.43.0.40", ports: "6379/TCP", age: "2h"),
]
```

- [ ] **Step 2: Surface them under the mock runtime**

In `AppStore.loadKubernetes()`, special-case the mock runtime so the tables render in snapshots:

```swift
guard runtimeKind != .mock else {
    kubernetesReachable = true
    kubernetesInfo = "v1.31.0 · 1 node · \(MockData.pods.count) pods · 4 namespaces"
    kubeNamespaces = ["default", "cache", "data", "jobs"]
    pods = MockData.pods
    deployments = MockData.deployments
    kubeServices = MockData.kubeServices
    return
}
```

(Replace the existing `guard runtimeKind != .mock else { kubernetesReachable = false; return }` first line.)

- [ ] **Step 3: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 4: Commit**

```bash
git add Dory/Runtime/MockData.swift Dory/Models/AppStore.swift
git commit -m "test(k8s): mock deployments/services so the cluster browser renders in snapshots"
```

---

## Task 11: Full build + snapshot verification

**Files:** none (verification only)

- [ ] **Step 1: Full build**

Run: `scripts/build.sh 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`, no `error:` / `warning:.*\.swift` lines.

- [ ] **Step 2: Run the full K8s unit suite**

Run: `scripts/test.sh -only-testing:DoryTests/KubeClientArgsTests -only-testing:DoryTests/KubeRowMapperTests -only-testing:DoryTests/KubeLogParserTests -only-testing:DoryTests/KubeContextHintTests -only-testing:DoryTests/KubeResourceKindTests 2>&1 | tail -15`
Expected: all PASS.

- [ ] **Step 3: Snapshot the cluster browser**

Run: `scripts/shots.sh 2>&1 | tail -10` (captures via `DORY_SECTION=kubernetes` on the mock backend). Confirm `/tmp/dory_*.png` for the Kubernetes section shows: the namespace + kind switcher, the Deployments and Services tables (switch the kind), and a pod's logs detail.

- [ ] **Step 4: Confirm no regressions**

Run: `scripts/test.sh 2>&1 | tail -20`
Expected: the full suite passes (the `KubeRowMapperTests.podsReproduceExistingMapping` regression confirms the Task 6 refactor preserved pod behavior).

- [ ] **Step 5: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "test(k8s): build + snapshot verification for K8s P1 cluster browser"
```

---

## Self-Review

**Spec coverage (Phase 1 items):**
- Pods/Deployments/Services list → Tasks 2, 8 ✓
- Namespace switcher → Tasks 7, 8 ✓
- Resource-kind switcher → Tasks 3, 8 ✓
- Pod logs (follow + copy) → Tasks 4, 7 (`podLogs`/`streamPodLogs`), 9 (auto-scroll + Copy) ✓
- Pod delete (confirmed) → Tasks 7 (`deletePod`), 8 (`confirmationDialog`) ✓
- Kubeconfig hint → Tasks 5, 7 (`kubeconfigHint`), 8 (menu item) ✓
- `KubeClient` seam + pure mappers → Tasks 1, 2 ✓
- Snapshot rendering without a cluster → Task 10 ✓

**Type consistency:** `KubeResourceKind.apiKind` returns `rawValue` (`"pods"`/`"deployments"`/`"services"`), matching the `kind:` strings passed to `KubeClient.getJSON`. Row `id`s are `"\(namespace)/\(name)"` for deployments/services and `name` for `Pod` (unchanged). `kubeErrorText` is `static` and called as `Self.kubeErrorText`. `namespaceFilter` maps the `"All Namespaces"` sentinel → `nil` consistently in both `loadKubeResource` and the pickers.

**Out of scope (P2/P3, do not implement here):** pod exec, deployment scale/restart, configmaps/secrets/ingress, service open-in-browser, generic resource delete, log search/filter, kubeconfig auto-merge.
