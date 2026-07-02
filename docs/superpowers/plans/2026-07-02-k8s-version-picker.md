# Kubernetes Version Picker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick a k3s version at cluster-enable time — the latest patch of the last ~3 k8s minors, defaulting to newest, persisted across launches — closing OrbStack's [#777](https://github.com/orbstack/orbstack/issues/777). Keep the existing enable/disable/kubeconfig machinery. Re-enabling at a different version is a confirmed destroy+recreate. `readiness.sh --k8s` stays green (version-agnostic `kubectl get nodes`).

**Architecture:** A pure, `Sendable` `KubeVersionCatalog` owns a curated newest-first list of `(minor, tag)` pairs — the single place `rancher/k3s` tags are declared. `KubernetesProvisioner` is parameterized by an `image: String` (default = catalog latest) instead of a hardcoded constant. `AppStore` persists the chosen tag (`UserDefaults`, mirroring `setAutoUpdate`) and passes the resolved image into `enableKubernetes()`. `KubernetesView` gains a compact version `Picker` in the empty state and a "Kubernetes Version" submenu + recreate `confirmationDialog` on a running cluster. All catalog/default/fallback logic is pure and unit-tested without a cluster.

**Tech Stack:** Swift 6 / SwiftUI, `@Observable` `AppStore`, the `Testing` framework (`@Test`/`#expect`, `@testable import Dory`), `Foundation`.

## Global Constraints

- **No line comments; no docstrings except on public-API functions that need them.** (repo CLAUDE.md)
- **Functional SwiftUI:** no ViewModels; `@Environment(AppStore.self)` + `@Environment(\.palette)`; views are pure state expressions.
- **Version source is the static curated `KubeVersionCatalog`.** No live network query for versions this cycle (design spec, "Access strategy decision").
- **No destructive action without a `confirmationDialog`.** A version switch on a *running* cluster recreates it (workloads lost) and MUST confirm first.
- **Build toolchain:** all builds/tests go through `scripts/build.sh` / `scripts/test.sh` (they export the correct `DEVELOPER_DIR`). New `.swift` files auto-compile via the target's `fileSystemSynchronizedGroups` — never edit `.pbxproj`, never open the Xcode GUI. `objectVersion` stays **77**. Ignore SourceKit false-positive errors in-editor; the script's `BUILD SUCCEEDED` + `xcodebuild_exit=0` is ground truth.
- **kubeconfig/readiness:** the cluster still writes `~/.kube/dory-config`; `readiness.sh --k8s` (`RUN_K8S=1`) must stay green. Do not modify `scripts/readiness.sh`.
- **Spec:** `docs/superpowers/specs/2026-07-02-k8s-version-picker-design.md`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Dory/Runtime/Kubernetes/KubeVersionCatalog.swift` (new) | `KubeVersion` + curated `all` (newest-first) + `latest` + `version(forTag:)` |
| `Dory/Runtime/Kubernetes/KubernetesProvisioner.swift` (modify) | `defaultImage` from catalog; `enable(runtime:image:progress:)` + `createBody(image:)` parameterized by tag |
| `Dory/Models/AppStore.swift` (modify) | `kubernetesVersionTag` state + `kubernetesVersionKey` persistence + `setKubernetesVersion` + `switchKubernetesVersion`; `enableKubernetes()` passes resolved image |
| `Dory/Features/Tables/KubernetesView.swift` (modify) | Version `Picker` in empty state; version submenu + recreate `confirmationDialog` on running cluster |
| `DoryTests/KubeVersionCatalogTests.swift` (new) | Catalog invariants + `version(forTag:)` fallback |
| `DoryTests/KubernetesProvisionerImageTests.swift` (new) | `defaultImage` == catalog latest; `createBody`/`createJSON` interpolates the tag |
| `DoryTests/AppStoreKubernetesVersionTests.swift` (new) | Default tag, `setKubernetesVersion` persist + round-trip |

---

## Task 1: KubeVersionCatalog (pure curated version list)

**Files:**
- Create: `Dory/Runtime/Kubernetes/KubeVersionCatalog.swift`
- Test: `DoryTests/KubeVersionCatalogTests.swift`

**Interfaces:**
- Produces: `struct KubeVersion: Identifiable, Hashable, Sendable { let minor: String; let tag: String; var id: String { tag }; var image: String { "rancher/k3s:\(tag)" } }`; `enum KubeVersionCatalog` with `static let all: [KubeVersion]` (newest-first, non-empty), `static var latest: KubeVersion { all[0] }`, `static func version(forTag tag: String?) -> KubeVersion`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Dory

struct KubeVersionCatalogTests {
    @Test func catalogIsNonEmptyNewestFirst() {
        #expect(!KubeVersionCatalog.all.isEmpty)
        #expect(KubeVersionCatalog.latest == KubeVersionCatalog.all[0])
    }

    @Test func tagsAreWellFormedK3sImages() {
        for version in KubeVersionCatalog.all {
            #expect(version.tag.hasPrefix("v"))
            #expect(version.tag.contains("-k3s"))
            #expect(version.image == "rancher/k3s:\(version.tag)")
        }
    }

    @Test func minorsAreDistinct() {
        let minors = KubeVersionCatalog.all.map(\.minor)
        #expect(Set(minors).count == minors.count)
    }

    @Test func versionForKnownTagResolves() {
        let known = KubeVersionCatalog.all[1]
        #expect(KubeVersionCatalog.version(forTag: known.tag) == known)
    }

    @Test func versionForNilFallsBackToLatest() {
        #expect(KubeVersionCatalog.version(forTag: nil) == KubeVersionCatalog.latest)
    }

    @Test func versionForUnknownTagFallsBackToLatest() {
        #expect(KubeVersionCatalog.version(forTag: "v0.0.0-nope") == KubeVersionCatalog.latest)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubeVersionCatalogTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'KubeVersionCatalog' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

struct KubeVersion: Identifiable, Hashable, Sendable {
    let minor: String
    let tag: String
    var id: String { tag }
    var image: String { "rancher/k3s:\(tag)" }
}

enum KubeVersionCatalog {
    // lastReviewed: 2026-07-02 — latest GA patch of the last three k8s minors on rancher/k3s.
    // Bump by a reviewed PR when a new minor ships; keep newest-first (index 0 is the default).
    static let all: [KubeVersion] = [
        KubeVersion(minor: "v1.34", tag: "v1.34.1-k3s1"),
        KubeVersion(minor: "v1.33", tag: "v1.33.4-k3s1"),
        KubeVersion(minor: "v1.32", tag: "v1.32.8-k3s1"),
    ]

    static var latest: KubeVersion { all[0] }

    static func version(forTag tag: String?) -> KubeVersion {
        guard let tag, let match = all.first(where: { $0.tag == tag }) else { return latest }
        return match
    }
}
```

> **Note for the implementer:** before committing, verify each `tag` is a real, currently-published `rancher/k3s` GA tag (Docker Hub / k3s releases). Use the newest GA patch per minor at implementation time; the values above are the pattern, not a guarantee of the exact patch numbers on that day. Do NOT include `-rc`/`-alpha` tags.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh -only-testing:DoryTests/KubeVersionCatalogTests 2>&1 | tail -20`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubeVersionCatalog.swift DoryTests/KubeVersionCatalogTests.swift
git commit -m "feat(k8s): curated KubeVersionCatalog of selectable k3s versions"
```

---

## Task 2: Parameterize KubernetesProvisioner by image tag

**Files:**
- Modify: `Dory/Runtime/Kubernetes/KubernetesProvisioner.swift`
- Test: `DoryTests/KubernetesProvisionerImageTests.swift`

**Interfaces:**
- Consumes: `KubeVersionCatalog.latest`.
- Produces: `static let defaultImage: String` (== `KubeVersionCatalog.latest.image`) replacing `static let image`; `static func enable(runtime:image:progress:)` with `image: String = defaultImage`; a pure `static func createJSON(image: String) -> String` (extracted from `createBody`) as the unit-test seam; `createBody(image:)` returns `Data(createJSON(image: image).utf8)`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Dory

struct KubernetesProvisionerImageTests {
    @Test func defaultImageIsCatalogLatest() {
        #expect(KubernetesProvisioner.defaultImage == KubeVersionCatalog.latest.image)
    }

    @Test func createJSONInterpolatesTheGivenImage() {
        let image = KubeVersionCatalog.all[2].image
        let json = KubernetesProvisioner.createJSON(image: image)
        #expect(json.contains("\"Image\":\"\(image)\""))
        #expect(json.contains("\"server\""))
        #expect(json.contains("--disable=traefik"))
        #expect(json.contains("PortBindings"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/KubernetesProvisionerImageTests 2>&1 | tail -20`
Expected: FAIL — `type 'KubernetesProvisioner' has no member 'defaultImage'` / `createJSON`.

- [ ] **Step 3: Write minimal implementation**

In `Dory/Runtime/Kubernetes/KubernetesProvisioner.swift`:

Replace the constant:

```swift
    static let containerName = "dory-k8s"
    static let image = "rancher/k3s:v1.31.5-k3s1"
```

with:

```swift
    static let containerName = "dory-k8s"
    static let defaultImage = KubeVersionCatalog.latest.image
```

Change the `enable` signature and its pull line:

```swift
    static func enable(runtime: any ContainerRuntime, image: String = defaultImage, progress: @Sendable (String) -> Void = { _ in }) async throws {
        if await isRunning(runtime) {
            try await writeKubeconfig(runtime)
            progress("Kubernetes is running")
            return
        }

        progress("Pulling Kubernetes (k3s)…")
        try? await runtime.pull(image: image)

        progress("Starting the cluster in the shared VM…")
        await deleteExisting(runtime)
        let encodedName = DockerImageOps.queryValue(containerName)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")], body: createBody(image: image)),
            create.statusCode == 201, let id = decodeId(create.body) else { throw K8sError.createFailed }
```

(the remaining lines of `enable` — start, Ready-wait, kubeconfig — are unchanged.)

Replace `createBody()` with a pure `createJSON(image:)` + a thin `createBody(image:)`:

```swift
    static func createJSON(image: String) -> String {
        """
        {"Image":"\(image)",\
        "Cmd":["server","--disable=traefik","--tls-san=127.0.0.1","--tls-san=host.docker.internal"],\
        "ExposedPorts":{"\(apiPort)/tcp":{}},\
        "HostConfig":{"Privileged":true,"PortBindings":{"\(apiPort)/tcp":[{"HostPort":"\(apiPort)"}]}}}
        """
    }

    private static func createBody(image: String) -> Data {
        Data(createJSON(image: image).utf8)
    }
```

> `createJSON` is `internal` (default) so the test can call it; `createBody` stays `private`. `disable`, `isRunning`, `deleteExisting`, `writeKubeconfig`, `decodeId` are untouched.

- [ ] **Step 4: Run test + build**

Run: `scripts/test.sh -only-testing:DoryTests/KubernetesProvisionerImageTests 2>&1 | tail -20` → Expected: PASS (2 tests).
Run: `scripts/build.sh 2>&1 | tail -5` → Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Dory/Runtime/Kubernetes/KubernetesProvisioner.swift DoryTests/KubernetesProvisionerImageTests.swift
git commit -m "feat(k8s): parameterize KubernetesProvisioner by k3s image tag"
```

---

## Task 3: AppStore version selection state + persistence + wiring

**Files:**
- Modify: `Dory/Models/AppStore.swift`
- Test: `DoryTests/AppStoreKubernetesVersionTests.swift`

**Interfaces:**
- Consumes: `KubeVersionCatalog`, `KubernetesProvisioner.enable(runtime:image:progress:)`, existing `disableKubernetes()`/`enableKubernetes()`, the `Self.<name>Key` + `UserDefaults` persistence pattern, the `realLaunch` gate in `init`.
- Produces on `AppStore`: `var kubernetesVersionTag: String`, `static let kubernetesVersionKey = "dory.kubernetesVersion"`, `func setKubernetesVersion(_ version: KubeVersion)`, `func switchKubernetesVersion(_ version: KubeVersion) async`; `enableKubernetes()` passes `KubeVersionCatalog.version(forTag: kubernetesVersionTag).image`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Dory

@MainActor
struct AppStoreKubernetesVersionTests {
    @Test func defaultsToCatalogLatest() {
        let store = AppStore()
        #expect(store.kubernetesVersionTag == KubeVersionCatalog.latest.tag)
    }

    @Test func setVersionUpdatesTagAndResolves() {
        let store = AppStore()
        let target = KubeVersionCatalog.all[2]
        store.setKubernetesVersion(target)
        #expect(store.kubernetesVersionTag == target.tag)
        #expect(KubeVersionCatalog.version(forTag: store.kubernetesVersionTag) == target)
        #expect(KubeVersionCatalog.version(forTag: store.kubernetesVersionTag).image == target.image)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh -only-testing:DoryTests/AppStoreKubernetesVersionTests 2>&1 | tail -20`
Expected: FAIL — `value of type 'AppStore' has no member 'kubernetesVersionTag'`.

- [ ] **Step 3: Write minimal implementation**

Add the stored property near the other kube state (after `var kubernetesInfo = "Cluster not running"`, AppStore.swift ~line 77):

```swift
    var kubernetesVersionTag: String = KubeVersionCatalog.latest.tag
```

Add the key alongside the other `static let …Key` declarations (AppStore.swift ~line 167):

```swift
    static let kubernetesVersionKey = "dory.kubernetesVersion"
```

Load the persisted value inside the `if realLaunch {` block in `init` (AppStore.swift ~line 109-127), next to the other persisted settings:

```swift
            if let saved = UserDefaults.standard.string(forKey: Self.kubernetesVersionKey) {
                kubernetesVersionTag = KubeVersionCatalog.version(forTag: saved).tag
            }
```

Add the setter near `setAutoUpdate`/`setRouteDockerCLI` (AppStore.swift ~line 186):

```swift
    func setKubernetesVersion(_ version: KubeVersion) {
        kubernetesVersionTag = version.tag
        UserDefaults.standard.set(version.tag, forKey: Self.kubernetesVersionKey)
    }
```

Pass the resolved image in `enableKubernetes()` (AppStore.swift ~line 815):

```swift
        do {
            try await KubernetesProvisioner.enable(
                runtime: runtime,
                image: KubeVersionCatalog.version(forTag: kubernetesVersionTag).image
            ) { message in
                Task { @MainActor in self.kubernetesInfo = message }
            }
        } catch {
            kubernetesInfo = "Kubernetes failed to start"
        }
```

Add the confirmed-recreate helper near `disableKubernetes()` (AppStore.swift ~line 824):

```swift
    func switchKubernetesVersion(_ version: KubeVersion) async {
        setKubernetesVersion(version)
        await disableKubernetes()
        await enableKubernetes()
    }
```

> `disableKubernetes()`/`enableKubernetes()` are each `kubernetesBusy`-guarded; `switchKubernetesVersion` runs them in sequence (await), so the guard on the second call sees the first has already reset `kubernetesBusy` in its `defer`.

- [ ] **Step 4: Run test + build**

Run: `scripts/test.sh -only-testing:DoryTests/AppStoreKubernetesVersionTests 2>&1 | tail -20` → Expected: PASS (2 tests).
Run: `scripts/build.sh 2>&1 | tail -5` → Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 5: Commit**

```bash
git add Dory/Models/AppStore.swift DoryTests/AppStoreKubernetesVersionTests.swift
git commit -m "feat(k8s): persist selected k3s version and wire it into enableKubernetes"
```

---

## Task 4: KubernetesView — version picker (empty state) + version switch (running cluster)

**Files:**
- Modify: `Dory/Features/Tables/KubernetesView.swift`

**Interfaces:**
- Consumes: `store.kubernetesVersionTag`, `store.setKubernetesVersion(_:)`, `store.switchKubernetesVersion(_:)`, `store.kubernetesBusy`, `store.runtimeKind`, `KubeVersionCatalog.all`, `KubeVersionCatalog.version(forTag:)`; existing `emptyState`/`banner` structure and the `⋯` `Menu`.
- Produces: a compact `Picker` in `emptyState` above the enable button; a "Kubernetes Version" submenu in the running-cluster `⋯` menu; `@State private var pendingVersionSwitch: KubeVersion?` driving a recreate `confirmationDialog`.

- [ ] **Step 1: Add the version picker to `emptyState`**

In `KubernetesView.emptyState`, immediately before the `Button { Task { await store.enableKubernetes() } }`, insert:

```swift
            Picker("", selection: Binding(
                get: { store.kubernetesVersionTag },
                set: { store.setKubernetesVersion(KubeVersionCatalog.version(forTag: $0)) }
            )) {
                ForEach(KubeVersionCatalog.all) { version in
                    Text(version.minor).tag(version.tag)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .labelsHidden()
            .disabled(store.kubernetesBusy || store.runtimeKind != .sharedVM)
            .accessibilityIdentifier("kube-version-picker")
```

And change the enable-button label to reflect the choice — replace the `Text(store.kubernetesBusy ? "Starting…" : "Enable Kubernetes")` line with:

```swift
                    Text(store.kubernetesBusy
                        ? "Starting…"
                        : "Enable Kubernetes \(KubeVersionCatalog.version(forTag: store.kubernetesVersionTag).minor)")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
```

- [ ] **Step 2: Add the version submenu + recreate confirm to the running-cluster surface**

Add the state to `KubernetesView`:

```swift
    @State private var pendingVersionSwitch: KubeVersion?
```

In `banner`'s `⋯` `Menu`, before the `Divider()` that precedes "Disable Kubernetes", insert a version submenu:

```swift
                Menu("Kubernetes Version") {
                    ForEach(KubeVersionCatalog.all) { version in
                        Button {
                            if version.tag != store.kubernetesVersionTag { pendingVersionSwitch = version }
                        } label: {
                            if version.tag == store.kubernetesVersionTag {
                                Label(version.minor, systemImage: "checkmark")
                            } else {
                                Text(version.minor)
                            }
                        }
                    }
                }
                Divider()
```

Attach the recreate confirmation to `clusterBrowser` (alongside its existing `.confirmationDialog` modifiers):

```swift
        .confirmationDialog(
            "Switch to \(pendingVersionSwitch?.minor ?? "")?",
            isPresented: Binding(get: { pendingVersionSwitch != nil }, set: { if !$0 { pendingVersionSwitch = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch & Recreate", role: .destructive) {
                if let version = pendingVersionSwitch { Task { await store.switchKubernetesVersion(version) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Switching recreates the cluster. All running workloads will be lost. This cannot be undone.")
        }
```

- [ ] **Step 3: Build**

Run: `scripts/build.sh 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`.

- [ ] **Step 4: Snapshot the empty state**

Run: `scripts/shots.sh 2>&1 | tail -10` (captures via `DORY_SECTION=kubernetes` on the mock backend). Confirm the Kubernetes empty-state `/tmp/dory_*.png` shows the version picker above the "Enable Kubernetes v1.34" button.

> If the mock runtime renders the cluster browser (not the empty state) because `MockData` reports a reachable cluster, the picker still compiles and the running-cluster submenu is the visible surface; capture whichever the mock backend shows and confirm the version control is present. No mock-data change is required for this task.

- [ ] **Step 5: Commit**

```bash
git add Dory/Features/Tables/KubernetesView.swift
git commit -m "feat(k8s): version picker in enable flow + confirmed version-switch recreate"
```

---

## Task 5: Full build + test + readiness verification

**Files:** none (verification only)

- [ ] **Step 1: Full build**

Run: `scripts/build.sh 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`, `xcodebuild_exit=0`, no `error:` / `warning:.*\.swift` lines. Confirm `objectVersion = 77` is unchanged in `Dory.xcodeproj/project.pbxproj` (`grep objectVersion Dory.xcodeproj/project.pbxproj`).

- [ ] **Step 2: Run the new unit suite**

Run: `scripts/test.sh -only-testing:DoryTests/KubeVersionCatalogTests -only-testing:DoryTests/KubernetesProvisionerImageTests -only-testing:DoryTests/AppStoreKubernetesVersionTests 2>&1 | tail -15`
Expected: all PASS.

- [ ] **Step 3: Full suite (no regressions)**

Run: `scripts/test.sh 2>&1 | tail -20`
Expected: the full suite passes — the provisioner change is behind a default that equals the previous behavior (latest catalog tag), and the existing k8s tests are untouched.

- [ ] **Step 4: readiness --k8s still green (if a shared-VM host is available)**

Run: `RUN_K8S=1 scripts/readiness.sh --k8s 2>&1 | tail -20` (requires `kubectl` + Dory's shared VM; on a host without them this SKIPs, which is expected). Confirm the `test_k8s` case PASSES for the default (latest) version — `kubectl get nodes` against `~/.kube/dory-config` is version-agnostic, so this is unaffected by the picker. No `readiness.sh` edit was made.

- [ ] **Step 5: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "test(k8s): build + version-picker verification"
```

---

## Self-Review

**Spec coverage:**
- Static curated version list (last ~3 minors) → Task 1 (`KubeVersionCatalog`) ✓
- Provisioner runs the selected tag → Task 2 (`enable(runtime:image:)`, `createJSON(image:)`) ✓
- Default to newest + persist last choice → Task 3 (`kubernetesVersionTag` defaulting to `latest`, `kubernetesVersionKey`, `init` load, `setKubernetesVersion`) ✓
- Picker in the enable flow, defaulting to newest → Task 4 (empty-state `Picker` bound to `kubernetesVersionTag`) ✓
- Re-enable at a different version = disable+recreate, confirmed → Task 3 (`switchKubernetesVersion`) + Task 4 (submenu + `confirmationDialog`) ✓
- Keep enable/disable/kubeconfig machinery → Tasks 2/3 change only the image parameter; `disable`/`writeKubeconfig`/`kubeconfigPath` untouched ✓
- `readiness --k8s` still passes → Task 5 Step 4; version-agnostic `kubectl get nodes`, no `readiness.sh` change ✓

**Type consistency:** `KubeVersion.image == "rancher/k3s:\(tag)"` is the exact shape the provisioner's `Image` field and `runtime.pull(image:)` expect. `KubernetesProvisioner.defaultImage == KubeVersionCatalog.latest.image` keeps the omit-argument path byte-identical to today for every existing caller. `kubernetesVersionTag` stores the `tag` (not the `minor`); every read resolves through `KubeVersionCatalog.version(forTag:)`, which never returns nil (falls back to `latest`). The `Picker` binds to the `tag` string and maps back via `version(forTag:)` in its setter.

**Build & tooling:** all three new files land under `Dory/Runtime/Kubernetes/` and `DoryTests/`, both inside `fileSystemSynchronizedGroups` — no `.pbxproj` edit, no Xcode GUI, `objectVersion` stays 77. Every task ends on `scripts/build.sh` / `scripts/test.sh`.

**Out of scope (do not implement here):** live version discovery (Docker Hub/k3s channel query), in-place upgrade, custom/free-text tags, multi-cluster/multi-node, distro choice, CI auto-bump of the catalog. (Design spec, "Non-goals".)
