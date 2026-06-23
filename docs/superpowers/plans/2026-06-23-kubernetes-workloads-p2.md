# Kubernetes Workload Surface — P2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the K8s cluster browser interactive — pod exec into a terminal window (reusing the shipped WS3 terminal-windowing), and deployment scale + rollout restart.

**Architecture:** Pod exec reuses the existing `TerminalSession` + `WindowGroup(for: TerminalSession.self)` scene — `TerminalSession` gains an optional `kubeExec` target; `ContainerTerminalView` runs `kubectl exec -it` instead of `docker exec` when that target is present. Deployment control extends the pure `KubeClient` seam (`scale`/`rolloutRestart` argv builders + transport) consumed by `AppStore`, surfaced through a new confirmed `DeploymentDetailView`. All command/argv construction is pure and unit-tested.

**Tech Stack:** Swift 6 / SwiftUI, `@Observable @MainActor AppStore`, `SwiftTerm` (`ContainerTerminalView`), the `Testing` framework (`@Test`/`#expect`, `@testable import Dory`).

## Global Constraints

- **No line comments; no docstrings except on public-API functions.** Functional SwiftUI (no ViewModels; `@Environment`; views as pure state expressions).
- **Transport is `kubectl` shell-out only**, behind the existing `KubeClient` seam. Exec runs through `/bin/zsh -lc "<command>"` so `kubectl` resolves from the login-shell PATH (identical to how container exec resolves `docker`).
- **Pod exec MUST reuse WS3 terminal-windowing** (`TerminalSession` + the existing `WindowGroup("Terminal", for: TerminalSession.self)` scene in `DoryApp.swift`). Do NOT add a new window scene or terminal view.
- **`TerminalSession.kubeExec` defaults to `nil` and must be Codable-backward-compatible:** an existing session JSON lacking the `kubeExec` key must decode to `nil` (synthesized `decodeIfPresent` for the optional). Existing container/machine factories must compile unchanged.
- **No destructive/mutating action without a `confirmationDialog`** (scale, restart): echo the target value. Failures route to the existing global `actionError` toast via `AppStore.kubeErrorText`.
- **Exec is offered only for running pods** (`pod.phase == .running`).
- **Build/test via repo scripts only:** `scripts/build.sh` / `scripts/test.sh` (they export the Xcode 27 beta `DEVELOPER_DIR`). Ignore SourceKit false "Cannot find … in scope" / "No such module 'Testing'" errors — `BUILD SUCCEEDED` / `xcodebuild_exit=0` is ground truth. Xcode synchronized folders auto-include new `.swift` files (no pbxproj edits).
- **Spec:** `docs/superpowers/specs/2026-06-23-kubernetes-workloads-design.md` (Phase 2). P1 is shipped (`KubeClient`, `KubeRowMapper`, `KubernetesView`, `PodDetailView`, `AppStore` kube state). P3 (configmaps/secrets/ingress, service open-in-browser) is a separate plan.

---

## File Structure

| File | Responsibility |
|---|---|
| `Dory/Runtime/Kubernetes/KubeExecCommand.swift` (new) | `KubeExecTarget` struct + pure `KubeExecCommand.shell(target:)` |
| `Dory/Runtime/TerminalSession.swift` (modify) | Add `var kubeExec: KubeExecTarget? = nil` |
| `Dory/Features/Containers/ContainerTerminalView.swift` (modify) | Branch to `kubectl exec` when `kubeExec` present |
| `Dory/Features/Containers/TerminalWindowView.swift` (modify) | Thread `session.kubeExec` into the embedded view + the "Terminal.app" button |
| `Dory/Runtime/Kubernetes/KubeClient.swift` (modify) | `scaleArgs`/`rolloutRestartArgs` (pure) + `scale`/`rolloutRestart` transport |
| `Dory/Runtime/Kubernetes/KubeModels.swift` (modify) | Add `replicas: Int` (desired) to `KubeDeploymentRow` + mapper |
| `Dory/Runtime/MockData.swift` (modify) | Add `replicas:` to the 3 mock deployment rows |
| `Dory/Models/AppStore.swift` (modify) | `terminalSession(for pod:)`, `scaleDeployment`, `restartDeployment`, `selectedDeploymentID`, `selectedDeployment()` |
| `Dory/Features/Tables/PodDetailView.swift` (modify) | "Exec" header action → `openWindow` |
| `Dory/Features/Tables/DeploymentDetailView.swift` (new) | Replica stepper + restart, both confirmed |
| `Dory/Features/Tables/KubernetesView.swift` (modify) | Deployment row double-tap → detail overlay |
| `DoryTests/KubeExecCommandTests.swift` (new), `KubeClientArgsTests.swift` / `KubeRowMapperTests.swift` / `TerminalSessionTests.swift` (extend) | Pure-logic unit tests |

---

## Task 1: KubeExecCommand (pure exec-command builder)

**Files:**
- Create: `Dory/Runtime/Kubernetes/KubeExecCommand.swift`
- Test: `DoryTests/KubeExecCommandTests.swift`

**Interfaces:**
- Produces: `struct KubeExecTarget: Hashable, Codable, Sendable { let pod: String; let namespace: String; let container: String?; let kubeconfig: String }`; `enum KubeExecCommand { static func shell(target: KubeExecTarget) -> String }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Dory

struct KubeExecCommandTests {
    @Test func execWithContainerAndKubeconfig() {
        let target = KubeExecTarget(pod: "web-1", namespace: "default", container: "app", kubeconfig: "/k")
        #expect(KubeExecCommand.shell(target: target)
            == "kubectl --kubeconfig /k exec -it web-1 -n default -c app -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func execWithoutContainer() {
        let target = KubeExecTarget(pod: "web-1", namespace: "default", container: nil, kubeconfig: "/k")
        #expect(KubeExecCommand.shell(target: target)
            == "kubectl --kubeconfig /k exec -it web-1 -n default -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }

    @Test func execWithEmptyKubeconfigOmitsFlag() {
        let target = KubeExecTarget(pod: "web-1", namespace: "default", container: nil, kubeconfig: "")
        #expect(KubeExecCommand.shell(target: target)
            == "kubectl exec -it web-1 -n default -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubeExecCommandTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'KubeExecTarget'/'KubeExecCommand' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct KubeExecTarget: Hashable, Codable, Sendable {
    let pod: String
    let namespace: String
    let container: String?
    let kubeconfig: String
}

enum KubeExecCommand {
    static func shell(target: KubeExecTarget) -> String {
        var parts = ["kubectl"]
        if !target.kubeconfig.isEmpty { parts += ["--kubeconfig", target.kubeconfig] }
        parts += ["exec", "-it", target.pod, "-n", target.namespace]
        if let container = target.container, !container.isEmpty { parts += ["-c", container] }
        parts += ["--", "sh", "-c", "'command -v bash >/dev/null && exec bash || exec sh'"]
        return parts.joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/KubeExecCommandTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubeExecCommand.swift DoryTests/KubeExecCommandTests.swift
git commit -m "feat(k8s): KubeExecTarget + pure KubeExecCommand.shell for pod exec"
```

---

## Task 2: TerminalSession.kubeExec + terminal-view kube branch

**Files:**
- Modify: `Dory/Runtime/TerminalSession.swift`
- Modify: `Dory/Features/Containers/ContainerTerminalView.swift`
- Modify: `Dory/Features/Containers/TerminalWindowView.swift`
- Test: `DoryTests/TerminalSessionTests.swift` (extend — add to the existing struct, do not rewrite it)

**Interfaces:**
- Consumes: `KubeExecTarget`, `KubeExecCommand.shell` (Task 1), `TerminalLauncher.execArgs`.
- Produces: `TerminalSession` gains `var kubeExec: KubeExecTarget? = nil` (last stored property, so the synthesized memberwise init gains a defaulted trailing param — existing `terminalSession(for container:)`/`(for machine:)` factories compile unchanged). `ContainerTerminalView` gains `var kubeExec: KubeExecTarget? = nil`.

- [ ] **Step 1: Write the failing tests**

Add these `@Test` methods to the existing `struct TerminalSessionTests` (read the file first; append, don't replace existing tests):

```swift
@Test func podSessionRoundTripsKubeExec() throws {
    let target = KubeExecTarget(pod: "web-1", namespace: "default", container: nil, kubeconfig: "/k")
    let session = TerminalSession(id: "pod:default/web-1", title: "web-1", subtitle: "default",
                                  logo: nil, socketPath: "", containerID: "", user: "root",
                                  shell: "/bin/sh", home: "/root", kubeExec: target)
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(TerminalSession.self, from: data)
    #expect(decoded.kubeExec == target)
}

@Test func legacySessionDecodesKubeExecAsNil() throws {
    let json = #"{"id":"container:abc","title":"c","subtitle":"img","logo":null,"socketPath":"/s","containerID":"abc","user":"root","shell":"/bin/sh","home":"/root"}"#
    let decoded = try JSONDecoder().decode(TerminalSession.self, from: Data(json.utf8))
    #expect(decoded.kubeExec == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/TerminalSessionTests 2>&1 | tail -20`
Expected: FAIL — `extra argument 'kubeExec' in call` / `value of type 'TerminalSession' has no member 'kubeExec'`.

- [ ] **Step 3: Add the field to `TerminalSession`**

In `Dory/Runtime/TerminalSession.swift`, add the field as the last stored property (after `home`):

```swift
    let home: String
    var kubeExec: KubeExecTarget? = nil
```

- [ ] **Step 4: Branch `ContainerTerminalView` to kubectl exec**

In `Dory/Features/Containers/ContainerTerminalView.swift`, add the param and branch the command:

```swift
struct ContainerTerminalView: NSViewRepresentable {
    let socketPath: String
    let containerID: String
    var user: String = "root"
    var shell: String = "/bin/sh"
    var home: String = "/root"
    var kubeExec: KubeExecTarget? = nil

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let exec: String
        if let kubeExec {
            exec = KubeExecCommand.shell(target: kubeExec)
        } else {
            exec = "docker -H unix://\(socketPath) \(TerminalLauncher.execArgs(user: user, shell: shell, home: home, container: containerID))"
        }
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        term.startProcess(executable: "/bin/zsh", args: ["-lc", exec], environment: env)
        return term
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
```

- [ ] **Step 5: Thread `kubeExec` through `TerminalWindowView`**

> NOTE: the spec said `TerminalWindowView` needs no change, but it passes individual fields (not the session) to `ContainerTerminalView` and builds the "Terminal.app" command itself — so `kubeExec` must thread through both. This is the intended correction.

In `Dory/Features/Containers/TerminalWindowView.swift`: pass `kubeExec: session.kubeExec` to `ContainerTerminalView`, and branch the header "Terminal.app" button:

```swift
ContainerTerminalView(socketPath: session.socketPath, containerID: session.containerID,
                      user: session.user, shell: session.shell, home: session.home,
                      kubeExec: session.kubeExec)
```

and replace the button's `TerminalLauncher.open(...)` call with:

```swift
Button {
    let command = session.kubeExec.map(KubeExecCommand.shell)
        ?? "docker -H unix://\(session.socketPath) " + TerminalLauncher.execArgs(user: session.user, shell: session.shell, home: session.home, container: session.containerID)
    TerminalLauncher.open(command: command)
} label: { … unchanged label … }
```

- [ ] **Step 6: Run test + build**

Run: `scripts/test.sh -only-testing:DoryTests/TerminalSessionTests 2>&1 | tail -20` → Expected: PASS (existing tests + the 2 new ones).
Run: `scripts/build.sh 2>&1 | tail -5` → Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 7: Commit**

```bash
git add Dory/Runtime/TerminalSession.swift Dory/Features/Containers/ContainerTerminalView.swift Dory/Features/Containers/TerminalWindowView.swift DoryTests/TerminalSessionTests.swift
git commit -m "feat(k8s): TerminalSession.kubeExec + terminal view runs kubectl exec for pods"
```

---

## Task 3: KubeClient scale/rollout + KubeDeploymentRow.replicas

**Files:**
- Modify: `Dory/Runtime/Kubernetes/KubeClient.swift`
- Modify: `Dory/Runtime/Kubernetes/KubeModels.swift`
- Modify: `Dory/Runtime/MockData.swift`
- Test: `DoryTests/KubeClientArgsTests.swift` (extend), `DoryTests/KubeRowMapperTests.swift` (extend)

**Interfaces:**
- Produces: `KubeClient.scaleArgs(deployment:namespace:replicas:kubeconfig:) -> [String]`, `KubeClient.rolloutRestartArgs(deployment:namespace:kubeconfig:) -> [String]`, `func scale(deployment:namespace:replicas:) async -> Result<Void, KubeError>`, `func rolloutRestart(deployment:namespace:) async -> Result<Void, KubeError>`; `KubeDeploymentRow` gains `var replicas: Int` (desired count, last init param).

- [ ] **Step 1: Write the failing tests**

Add to `struct KubeClientArgsTests`:

```swift
@Test func scaleArgsBuildReplicaFlag() {
    #expect(KubeClient.scaleArgs(deployment: "web", namespace: "default", replicas: 3, kubeconfig: "/k")
        == ["--kubeconfig", "/k", "scale", "deployment", "web", "-n", "default", "--replicas=3"])
}

@Test func rolloutRestartArgsBuild() {
    #expect(KubeClient.rolloutRestartArgs(deployment: "web", namespace: "default", kubeconfig: "/k")
        == ["--kubeconfig", "/k", "rollout", "restart", "deployment", "web", "-n", "default"])
}
```

Add to `KubeRowMapperTests.deploymentReadyRatio()` (after the existing assertions):

```swift
#expect(rows[0].replicas == 3)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test.sh -only-testing:DoryTests/KubeClientArgsTests -only-testing:DoryTests/KubeRowMapperTests 2>&1 | tail -20`
Expected: FAIL — `type 'KubeClient' has no member 'scaleArgs'` and `value of type 'KubeDeploymentRow' has no member 'replicas'`.

- [ ] **Step 3: Add the `replicas` field + mapper**

In `Dory/Runtime/Kubernetes/KubeModels.swift`, add `var replicas: Int` to `KubeDeploymentRow` (after `available`, before `age` is fine — but to keep the memberwise-init call sites readable, add it as the LAST field after `age`):

```swift
struct KubeDeploymentRow: Identifiable, Hashable, Sendable {
    var name: String
    var namespace: String
    var ready: String
    var upToDate: Int
    var available: Int
    var age: String
    var replicas: Int
    var id: String { "\(namespace)/\(name)" }
}
```

In `KubeRowMapper.deployments`, pass it (the mapper already computes `let desired = dep.spec?.replicas ?? 0`):

```swift
return KubeDeploymentRow(
    name: name, namespace: dep.metadata?.namespace ?? "default",
    ready: "\(ready)/\(desired)", upToDate: dep.status?.updatedReplicas ?? 0,
    available: dep.status?.availableReplicas ?? 0,
    age: DockerFormat.relative(iso: dep.metadata?.creationTimestamp),
    replicas: desired
)
```

- [ ] **Step 4: Update mock rows**

In `Dory/Runtime/MockData.swift`, add `replicas:` to each of the 3 `KubeDeploymentRow(...)` literals (match the desired in `ready`):

```swift
KubeDeploymentRow(name: "web", namespace: "default", ready: "2/2", upToDate: 2, available: 2, age: "42m", replicas: 2),
KubeDeploymentRow(name: "redis", namespace: "cache", ready: "1/1", upToDate: 1, available: 1, age: "2h", replicas: 1),
KubeDeploymentRow(name: "worker", namespace: "jobs", ready: "0/1", upToDate: 1, available: 0, age: "5m", replicas: 1),
```

- [ ] **Step 5: Add the KubeClient methods**

In `Dory/Runtime/Kubernetes/KubeClient.swift`, add inside `struct KubeClient`:

```swift
static func scaleArgs(deployment: String, namespace: String, replicas: Int, kubeconfig: String?) -> [String] {
    var args: [String] = []
    if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
    args += ["scale", "deployment", deployment, "-n", namespace, "--replicas=\(replicas)"]
    return args
}

static func rolloutRestartArgs(deployment: String, namespace: String, kubeconfig: String?) -> [String] {
    var args: [String] = []
    if let kubeconfig, !kubeconfig.isEmpty { args += ["--kubeconfig", kubeconfig] }
    args += ["rollout", "restart", "deployment", deployment, "-n", namespace]
    return args
}

func scale(deployment: String, namespace: String, replicas: Int) async -> Result<Void, KubeError> {
    guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
    let result = await Shell.runAsyncResult(kubectl, Self.scaleArgs(deployment: deployment, namespace: namespace, replicas: replicas, kubeconfig: Self.kubeconfig()))
    return result.exit == 0 ? .success(()) : .failure(.nonZero(result.exit, result.output))
}

func rolloutRestart(deployment: String, namespace: String) async -> Result<Void, KubeError> {
    guard let kubectl = kubectlPath else { return .failure(.kubectlMissing) }
    let result = await Shell.runAsyncResult(kubectl, Self.rolloutRestartArgs(deployment: deployment, namespace: namespace, kubeconfig: Self.kubeconfig()))
    return result.exit == 0 ? .success(()) : .failure(.nonZero(result.exit, result.output))
}
```

- [ ] **Step 6: Run tests + build**

Run: `scripts/test.sh -only-testing:DoryTests/KubeClientArgsTests -only-testing:DoryTests/KubeRowMapperTests 2>&1 | tail -20` → Expected: PASS.
Run: `scripts/build.sh 2>&1 | tail -5` → Expected: `BUILD SUCCEEDED` (confirms the mock-row + mapper changes compile).

- [ ] **Step 7: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubeClient.swift Dory/Runtime/Kubernetes/KubeModels.swift Dory/Runtime/MockData.swift DoryTests/KubeClientArgsTests.swift DoryTests/KubeRowMapperTests.swift
git commit -m "feat(k8s): KubeClient scale/rollout-restart + KubeDeploymentRow.replicas"
```

---

## Task 4: AppStore P2 wiring

**Files:**
- Modify: `Dory/Models/AppStore.swift`

**Interfaces:**
- Consumes: `KubeExecTarget`, `KubeClient.scale`/`rolloutRestart`, `KubeClient.kubeconfig()`, existing `kubeClient`, `actionError`, `kubeErrorText`, `loadKubeResource`, `deployments`.
- Produces on `AppStore`: `func terminalSession(for pod: Pod) -> TerminalSession`; `var selectedDeploymentID: String? = nil`; `func selectedDeployment() -> KubeDeploymentRow?`; `func scaleDeployment(_ deployment: KubeDeploymentRow, replicas: Int) async`; `func restartDeployment(_ deployment: KubeDeploymentRow) async`.

- [ ] **Step 1: Add the pod terminal factory**

Next to the existing `terminalSession(for container:)` / `terminalSession(for machine:)` factories (around AppStore.swift:1643):

```swift
func terminalSession(for pod: Pod) -> TerminalSession {
    TerminalSession(id: "pod:\(pod.namespace)/\(pod.name)", title: pod.name, subtitle: pod.namespace,
                    logo: nil, socketPath: "", containerID: "", user: "root", shell: "/bin/sh", home: "/root",
                    kubeExec: KubeExecTarget(pod: pod.name, namespace: pod.namespace, container: nil, kubeconfig: KubeClient.kubeconfig() ?? ""))
}
```

- [ ] **Step 2: Add deployment selection + mutations**

Near the P1 kube state (`selectedPodID`, `deletePod`):

```swift
var selectedDeploymentID: String? = nil
func selectedDeployment() -> KubeDeploymentRow? { deployments.first { $0.id == selectedDeploymentID } }

func scaleDeployment(_ deployment: KubeDeploymentRow, replicas: Int) async {
    switch await kubeClient.scale(deployment: deployment.name, namespace: deployment.namespace, replicas: replicas) {
    case .success: await loadKubeResource()
    case .failure(let error): actionError = Self.kubeErrorText(error)
    }
}

func restartDeployment(_ deployment: KubeDeploymentRow) async {
    switch await kubeClient.rolloutRestart(deployment: deployment.name, namespace: deployment.namespace) {
    case .success: await loadKubeResource()
    case .failure(let error): actionError = Self.kubeErrorText(error)
    }
}
```

- [ ] **Step 3: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`, no new warnings on AppStore.swift.

- [ ] **Step 4: Commit**

```bash
git add Dory/Models/AppStore.swift
git commit -m "feat(k8s): AppStore pod-exec session factory + deployment scale/restart"
```

---

## Task 5: PodDetailView Exec action

**Files:**
- Modify: `Dory/Features/Tables/PodDetailView.swift`

**Interfaces:**
- Consumes: `store.terminalSession(for: pod)`, `@Environment(\.openWindow)`.

- [ ] **Step 1: Add the openWindow environment + Exec button**

Add `@Environment(\.openWindow) private var openWindow` to `PodDetailView`. In `header`, insert an "Exec" button immediately before the "Done" button:

```swift
Button("Exec") { openWindow(value: store.terminalSession(for: pod)) }
    .buttonStyle(.plain).foregroundStyle(p.accentText)
    .disabled(pod.phase != .running)
    .accessibilityIdentifier("pod-exec")
Button("Done") { store.selectedPodID = nil }.buttonStyle(.plain).foregroundStyle(p.accentText)
```

- [ ] **Step 2: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 3: Commit**

```bash
git add Dory/Features/Tables/PodDetailView.swift
git commit -m "feat(k8s): pod Exec action opens a kubectl-exec terminal window"
```

---

## Task 6: DeploymentDetailView + KubernetesView wiring

**Files:**
- Create: `Dory/Features/Tables/DeploymentDetailView.swift`
- Modify: `Dory/Features/Tables/KubernetesView.swift`

**Interfaces:**
- Consumes: `KubeDeploymentRow` (incl. `replicas`), `store.scaleDeployment`, `store.restartDeployment`, `store.selectedDeployment()`, `store.selectedDeploymentID`.

- [ ] **Step 1: Create `DeploymentDetailView`**

```swift
import SwiftUI

struct DeploymentDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var p
    let deployment: KubeDeploymentRow
    @State private var replicas: Int
    @State private var confirmingScale = false
    @State private var confirmingRestart = false

    init(deployment: KubeDeploymentRow) {
        self.deployment = deployment
        _replicas = State(initialValue: deployment.replicas)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bgContent)
        .confirmationDialog(
            "Scale \(deployment.name) to \(replicas) replica\(replicas == 1 ? "" : "s")?",
            isPresented: $confirmingScale, titleVisibility: .visible
        ) {
            Button("Scale") { Task { await store.scaleDeployment(deployment, replicas: replicas) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes the desired replica count for this deployment.")
        }
        .confirmationDialog(
            "Restart \(deployment.name)?",
            isPresented: $confirmingRestart, titleVisibility: .visible
        ) {
            Button("Restart") { Task { await store.restartDeployment(deployment) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Triggers a rolling restart of all pods in this deployment.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(deployment.name).font(.mono(14, weight: .semibold)).foregroundStyle(p.text)
            Text(deployment.namespace).font(.system(size: 12)).foregroundStyle(p.text3)
            Text("Ready \(deployment.ready)").font(.system(size: 12)).foregroundStyle(p.text2)
            Spacer()
            Button("Done") { store.selectedDeploymentID = nil }.buttonStyle(.plain).foregroundStyle(p.accentText)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Stepper(value: $replicas, in: 0...50) {
                    Text("Replicas: \(replicas)").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.text)
                }
                .fixedSize()
                Button("Apply") { confirmingScale = true }
                    .buttonStyle(DoryButtonStyle(kind: .primary))
                    .disabled(replicas == deployment.replicas)
            }
            Button("Restart Deployment") { confirmingRestart = true }
                .buttonStyle(DoryButtonStyle(kind: .secondary))
        }
        .padding(18)
    }
}
```

> If `DoryButtonStyle(kind:)` cases differ, mirror whatever `ImagesView`/`VolumesView` use for primary/secondary buttons — read one before writing.

- [ ] **Step 2: Wire the deployment row + overlay in `KubernetesView`**

In `deploymentTable`, make the row open the detail on double-tap — add to the row's `HStack` (the one ending in `.tableRow()`):

```swift
.tableRow()
.contentShape(Rectangle())
.onTapGesture(count: 2) { store.selectedDeploymentID = row.id }
```

In `clusterBrowser`, add a second `.overlay` (after the existing pod overlay) gated on the deployments kind:

```swift
.overlay {
    if store.kubeResource == .deployments, let dep = store.selectedDeployment() {
        DeploymentDetailView(deployment: dep).background(p.bgContent).transition(.move(edge: .trailing))
    }
}
```

- [ ] **Step 3: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 4: Commit**

```bash
git add Dory/Features/Tables/DeploymentDetailView.swift Dory/Features/Tables/KubernetesView.swift
git commit -m "feat(k8s): DeploymentDetailView — confirmed replica scale + rollout restart"
```

---

## Task 7: Full build + snapshot verification

**Files:** none (verification only)

- [ ] **Step 1: Full build**

Run: `scripts/build.sh 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`, no `error:` / `warning:.*\.swift`.

- [ ] **Step 2: Run the P2 + regression unit suites**

Run: `scripts/test.sh -only-testing:DoryTests/KubeExecCommandTests -only-testing:DoryTests/KubeClientArgsTests -only-testing:DoryTests/KubeRowMapperTests -only-testing:DoryTests/TerminalSessionTests 2>&1 | tail -20`
Expected: all PASS (new exec/scale/replicas tests + the TerminalSession Codable back-compat tests + the P1 regression locks).

- [ ] **Step 3: Snapshot the cluster browser (regression)**

Build the signed app and capture the Kubernetes section under mock (`DORY_SECTION=kubernetes DORY_RUNTIME=mock`); confirm the cluster browser still renders. (Pod exec opens a separate terminal window and `DeploymentDetailView` requires double-tap — neither is reachable via env, so they are build- + unit- + review-verified; note this in the report.)

- [ ] **Step 4: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "test(k8s): build + snapshot verification for K8s P2 (exec + deployment control)"
```

---

## Self-Review

**Spec coverage (Phase 2 items):**
- `KubeExecTarget` + `KubeExecCommand.shell` → Task 1 ✓
- `TerminalSession.kubeExec` (default nil, Codable back-compat) → Task 2 ✓
- `ContainerTerminalView` kubectl-exec branch → Task 2 ✓ (+ `TerminalWindowView` threading — noted deviation)
- `AppStore.terminalSession(for pod:)` + `scaleDeployment`/`restartDeployment` → Task 4 (factory), Task 3 (KubeClient transport) ✓
- `PodDetailView` Exec action → Task 5 ✓
- `DeploymentDetailView` (confirmed scale + restart) → Task 6 ✓

**Type consistency:** `KubeExecTarget` field order (`pod, namespace, container, kubeconfig`) is identical in the struct, the `KubeExecCommand.shell` body, the `terminalSession(for pod:)` factory, and the tests. `KubeDeploymentRow.replicas` is the new last init param, applied consistently in the mapper, the 3 mock rows, and the `DeploymentDetailView` stepper seed. `scaleDeployment`/`restartDeployment` take a `KubeDeploymentRow` (not strings) and pass `.name`/`.namespace` through to `KubeClient`. Both detail overlays gate on their `kubeResource` so only one shows.

**Back-compat:** `TerminalSession.kubeExec` is optional with a memberwise-init default, so the two existing factories compile unchanged and legacy session JSON decodes `kubeExec` as nil (Task 2's `legacySessionDecodesKubeExecAsNil` locks this).

**Non-goals (do NOT implement here):** configmaps/secrets/ingress, service open-in-browser, generic resource delete, multi-container exec picker (container is modeled optional but P2 always passes the first/default), StatefulSet/DaemonSet scaling.
