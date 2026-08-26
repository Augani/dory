import Foundation

/// One-click Kubernetes: runs a k3s server as a container inside Dory's shared VM (the k3d pattern),
/// publishes the API on :6443 (auto-forwarded to `localhost` by the port forwarder), and writes a
/// kubeconfig the host `kubectl` picks up — mirroring OrbStack's built-in cluster. NOTE: k3s brings
/// its own embedded containerd image store, SEPARATE from the shared engine's dockerd store. A
/// locally-built Docker image is therefore NOT automatically visible to Pods — push it to a registry
/// the cluster can reach, or import it into k3s's containerd (`k8s.io` namespace). Auto image-sync is
/// a tracked follow-up.
enum KubernetesProvisioner {
    static let containerName = "dory-k8s"
    nonisolated static let defaultImage = KubeVersionCatalog.latest.image
    static let apiPort = 6443
    static var kubeconfigPath: String { "\(NSHomeDirectory())/.kube/dory-config" }

    /// Increment whenever the container's mounts or nested containerd runtime contract changes.
    /// A mismatched container is never replaced automatically because its writable layer contains
    /// the user's cluster state.
    static let runtimeContract = "3"
    static let contractLabel = "dev.dory.kubernetes.contract"
    static let emulationLabel = "dev.dory.kubernetes.amd64"
    static let imageLabel = "dev.dory.kubernetes.image"
    static let fexWrapperPath = "/usr/local/bin/dory-runc"

    enum K8sError: Error, Sendable, CustomStringConvertible {
        case createFailed(String)
        case notReady(String)
        case kubeconfigFailed(String)
        case kubectlMissing
        case apiUnreachable(String)
        case containerExited(String)
        case recreationRequired(String)

        var description: String {
            switch self {
            case .createFailed(let detail):
                return detail.isEmpty ? "could not create the k3s container" : "could not create the k3s container: \(detail)"
            case .notReady(let detail):
                return detail.isEmpty ? "k3s did not become Ready before the timeout" : "k3s did not become Ready: \(detail)"
            case .kubeconfigFailed(let detail):
                return detail.isEmpty ? "could not read the k3s kubeconfig" : "could not read the k3s kubeconfig: \(detail)"
            case .kubectlMissing:
                return "kubectl is missing"
            case .apiUnreachable(let detail):
                return detail.isEmpty ? "the Kubernetes API is not reachable from macOS" : "the Kubernetes API is not reachable from macOS: \(detail)"
            case .containerExited(let detail):
                return detail.isEmpty ? "the k3s container exited during startup" : "the k3s container exited during startup: \(detail)"
            case .recreationRequired(let detail):
                let prefix = "this Kubernetes cluster uses an older or different runtime contract"
                return "\(prefix)\(detail.isEmpty ? "" : " (\(detail))"). Export any cluster-only workloads, then use Disable & Remove Cluster and enable Kubernetes again. Dory did not modify or remove the existing cluster."
            }
        }
    }

    static func enable(
        runtime: any ContainerRuntime,
        image: String = defaultImage,
        amd64Emulation: Bool = false,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws {
        if let existing = try await containerInspect(runtime) {
            guard existing.matches(image: image, amd64Emulation: amd64Emulation) else {
                throw K8sError.recreationRequired(existing.mismatchDetail(image: image, amd64Emulation: amd64Emulation))
            }

            if existing.State?.running != true {
                progress("Restarting the existing Kubernetes cluster…")
                try await startContainer(runtime, id: containerName)
            }
            try await waitUntilReady(runtime, amd64Emulation: amd64Emulation, progress: progress)
            return
        }

        progress("Pulling Kubernetes (k3s)…")
        try? await runtime.pull(image: image)

        progress("Starting the cluster in the shared VM…")
        let encodedName = DockerImageOps.queryValue(containerName)
        guard let create = await runtime.proxyRequest(
            method: "POST",
            path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")],
            body: createBody(image: image, amd64Emulation: amd64Emulation)
        ) else {
            throw K8sError.createFailed("")
        }
        guard create.statusCode == 201, let id = decodeId(create.body) else {
            throw K8sError.createFailed(createFailureDetail(create.body))
        }
        try await startContainer(runtime, id: id)
        try await waitUntilReady(runtime, amd64Emulation: amd64Emulation, progress: progress)
    }

    static func disable(runtime: any ContainerRuntime) async {
        await deleteExisting(runtime)
        try? FileManager.default.removeItem(atPath: kubeconfigPath)
    }

    static func createJSON(image: String, amd64Emulation: Bool = false) -> String {
        String(decoding: createBody(image: image, amd64Emulation: amd64Emulation), as: UTF8.self)
    }

    private struct EmptyObject: Encodable {}

    private struct PortBinding: Encodable {
        let HostPort: String
    }

    private struct HostConfiguration: Encodable {
        let Privileged = true
        let PortBindings: [String: [PortBinding]]
    }

    private struct CreateRequest: Encodable {
        let Image: String
        let Cmd: [String]
        let Entrypoint: [String]?
        let Labels: [String: String]
        let ExposedPorts: [String: EmptyObject]
        let HostConfig: HostConfiguration
    }

    private static let serverArguments = [
        "server",
        "--disable=traefik",
        "--tls-san=127.0.0.1",
        "--tls-san=host.docker.internal",
    ]

    /// Dory's engine OCI admission layer interposes the exact nested runc as runc.real and mounts
    /// dory-runc into this privileged container. Configure only containerd's BinaryName here; the
    /// app must not copy or replace runtime binaries from inside the container after admission.
    static let fexStartupScript = #"""
    set -eu
    test -x /usr/lib/dory/fex/FEX
    test -x /usr/lib/dory/fex/FEXServer
    test -x /usr/local/bin/dory-runc
    test -x /usr/local/bin/runc.real
    install -d -m 0755 /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
    runtime_config=/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/10-dory-fex.toml
    runtime_config_tmp="${runtime_config}.tmp"
    umask 022
    printf '%s\n' \
      '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]' \
      '  BinaryName = "/usr/local/bin/dory-runc"' > "${runtime_config_tmp}"
    chmod 0644 "${runtime_config_tmp}"
    mv -f "${runtime_config_tmp}" "${runtime_config}"

    # containerd resolves indexes against the native platform before OCI runtime selection. Keep
    # native pulls as the first choice, then repair only the exact public amd64-only index failure
    # by installing its selected manifest as the CRI-managed tag. Running this as a regular k3s
    # workload keeps k3s as PID 1, which its cgroup-v2 initialization requires.
    install -d -m 0755 /var/lib/rancher/k3s/server/manifests
    resolver_manifest=/var/lib/rancher/k3s/server/manifests/dory-amd64-resolver.yaml
    resolver_manifest_tmp="${resolver_manifest}.tmp"
    cat > "${resolver_manifest_tmp}" <<'DORY_AMD64_RESOLVER'
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: dory-amd64-resolver
      namespace: kube-system
      labels:
        app.kubernetes.io/managed-by: dory
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: dory-amd64-resolver
      labels:
        app.kubernetes.io/managed-by: dory
    rules:
      - apiGroups: [""]
        resources: ["events"]
        verbs: ["get", "list", "watch"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: dory-amd64-resolver
      labels:
        app.kubernetes.io/managed-by: dory
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: dory-amd64-resolver
    subjects:
      - kind: ServiceAccount
        name: dory-amd64-resolver
        namespace: kube-system
    ---
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: dory-amd64-resolver
      namespace: kube-system
      labels:
        app.kubernetes.io/managed-by: dory
    data:
      resolver.sh: |
        #!/bin/sh
        set -u
        resolved=/run/dory/resolver.resolved
        attempts=/run/dory/resolver.attempts
        events=/run/dory/resolver.events
        pull_log=/run/dory/resolver.log
        ready=/run/dory/resolver.ready
        token=/var/run/secrets/kubernetes.io/serviceaccount/token
        ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        umask 077
        : > "${resolved}"
        : > "${attempts}"
        kubectl() {
          /usr/local/bin/kubectl \
            --server="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT_HTTPS}" \
            --token="$(cat "${token}")" \
            --certificate-authority="${ca}" "$@"
        }
        while :; do
          if kubectl get events -A --field-selector reason=Failed \
            -o go-template='{{range .items}}{{.message}}{{"\n"}}{{end}}' > "${events}" 2>/dev/null; then
            : > "${ready}"
            sed -n 's/.*failed to pull and unpack image "\([^"]*\)".*no match for platform in manifest.*/\1/p' "${events}" \
              | while IFS= read -r image; do
                  [ -n "${image}" ] || continue
                  grep -Fqx "${image}" "${resolved}" 2>/dev/null && continue
                  attempt_count=$(grep -Fxc "${image}" "${attempts}" 2>/dev/null || true)
                  [ "${attempt_count}" -lt 3 ] || continue
                  printf '%s\n' "${image}" >> "${attempts}"
                  if /usr/local/bin/ctr -n k8s.io images pull --platform linux/amd64 "${image}" > "${pull_log}" 2>&1; then
                    manifest=$(/usr/local/bin/ctr -n k8s.io images inspect "${image}" 2>/dev/null \
                      | awk '/image.manifest.*@sha256:/ { candidate=$0; sub(/^.*@/, "", candidate); sub(/ .*/, "", candidate) } /Platform: linux\/amd64/ { print candidate; exit }')
                    case "${manifest}" in sha256:*) ;; *) manifest= ;; esac
                    leaf=${image##*/}
                    case "${leaf}" in *:*) repository=${image%:*} ;; *) repository=${image} ;; esac
                    direct="${repository}@${manifest}"
                    if [ -n "${manifest}" ] \
                      && /usr/local/bin/crictl pull "${direct}" >> "${pull_log}" 2>&1 \
                      && /usr/local/bin/ctr -n k8s.io images tag --force --local "${direct}" "${image}" >> "${pull_log}" 2>&1 \
                      && /usr/local/bin/ctr -n k8s.io images label "${image}" io.cri-containerd.image=managed >> "${pull_log}" 2>&1; then
                      printf '%s\n' "${image}" >> "${resolved}"
                      printf 'Dory resolved amd64 image %s\n' "${image}"
                    fi
                  fi
                done
          else
            rm -f "${ready}"
          fi
          sleep 10
        done
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: dory-amd64-resolver
      namespace: kube-system
      labels:
        app.kubernetes.io/name: dory-amd64-resolver
        app.kubernetes.io/managed-by: dory
    spec:
      replicas: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: dory-amd64-resolver
      template:
        metadata:
          labels:
            app.kubernetes.io/name: dory-amd64-resolver
            app.kubernetes.io/managed-by: dory
        spec:
          serviceAccountName: dory-amd64-resolver
          priorityClassName: system-node-critical
          containers:
            - name: resolver
              image: alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "/opt/dory/resolver.sh"]
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                runAsNonRoot: false
                runAsUser: 0
                capabilities:
                  drop: ["ALL"]
              readinessProbe:
                exec:
                  command: ["/bin/sh", "-ec", "test -f /run/dory/resolver.ready && test -S /run/k3s/containerd/containerd.sock"]
                initialDelaySeconds: 1
                periodSeconds: 2
                timeoutSeconds: 1
                failureThreshold: 3
              resources:
                requests:
                  cpu: 10m
                  memory: 16Mi
                limits:
                  cpu: 500m
                  memory: 256Mi
              volumeMounts:
                - name: kubectl
                  mountPath: /usr/local/bin/kubectl
                  readOnly: true
                - name: ctr
                  mountPath: /usr/local/bin/ctr
                  readOnly: true
                - name: crictl
                  mountPath: /usr/local/bin/crictl
                  readOnly: true
                - name: containerd
                  mountPath: /run/k3s/containerd
                - name: script
                  mountPath: /opt/dory
                  readOnly: true
                - name: runtime
                  mountPath: /run/dory
          volumes:
            - name: kubectl
              hostPath:
                path: /bin/kubectl
                type: File
            - name: ctr
              hostPath:
                path: /bin/ctr
                type: File
            - name: crictl
              hostPath:
                path: /bin/crictl
                type: File
            - name: containerd
              hostPath:
                path: /run/k3s/containerd
                type: Directory
            - name: script
              configMap:
                name: dory-amd64-resolver
                defaultMode: 0555
            - name: runtime
              emptyDir:
                sizeLimit: 4Mi
    DORY_AMD64_RESOLVER
    chmod 0600 "${resolver_manifest_tmp}"
    mv -f "${resolver_manifest_tmp}" "${resolver_manifest}"
    exec /bin/k3s server --disable=traefik --tls-san=127.0.0.1 --tls-san=host.docker.internal
    """#

    private static func createBody(image: String, amd64Emulation: Bool) -> Data {
        let port = "\(apiPort)/tcp"
        let labels = [
            contractLabel: runtimeContract,
            emulationLabel: amd64Emulation ? "fex" : "disabled",
            imageLabel: image,
        ]
        let request = CreateRequest(
            Image: image,
            Cmd: amd64Emulation ? [fexStartupScript] : serverArguments,
            Entrypoint: amd64Emulation ? ["/bin/sh", "-ec"] : nil,
            Labels: labels,
            ExposedPorts: [port: EmptyObject()],
            HostConfig: HostConfiguration(
                PortBindings: [port: [PortBinding(HostPort: "\(apiPort)")]]
            )
        )
        // All fields above are JSON-encodable value types. Encoding rather than interpolation keeps
        // image names and future arguments from ever changing the shape of the Docker API request.
        do {
            return try JSONEncoder().encode(request)
        } catch {
            preconditionFailure("Kubernetes create request contains a non-encodable value: \(error)")
        }
    }

    private static func waitUntilReady(
        _ runtime: any ContainerRuntime,
        amd64Emulation: Bool,
        progress: @Sendable (String) -> Void
    ) async throws {
        progress("Waiting for the node to become Ready…")
        var lastProbe = ""
        for attempt in 0..<90 {
            if let state = await containerState(runtime), !state.running {
                throw K8sError.containerExited(await startupLogTail(runtime))
            }
            if let result = try? await runtime.exec(
                containerID: containerName,
                command: [
                    "kubectl", "get", "nodes",
                    "-o", "jsonpath={.items[0].status.conditions[?(@.type==\"Ready\")].status}",
                ]
            ) {
                lastProbe = result.output
                let resolverReady: Bool
                if amd64Emulation {
                    resolverReady = await isAMD64ResolverReady(runtime)
                } else {
                    resolverReady = true
                }
                let nodeReady = nodeProbeIsReady(output: result.output, exitCode: result.exitCode)
                if nodeReady, resolverReady {
                    try await writeKubeconfig(runtime)
                    progress("Waiting for Kubernetes API access…")
                    try await waitForHostAPI(runtime, progress: progress)
                    progress("Kubernetes is running")
                    return
                }
            }
            if attempt == 20 || attempt == 45 || attempt == 70 {
                progress("Still waiting for k3s networking and the API server…")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw K8sError.notReady(lastProbe.isEmpty ? await startupLogTail(runtime) : lastProbe)
    }

    static func nodeProbeIsReady(output: String, exitCode: Int) -> Bool {
        exitCode == 0 && output.trimmingCharacters(in: .whitespacesAndNewlines) == "True"
    }

    private static func isAMD64ResolverReady(_ runtime: any ContainerRuntime) async -> Bool {
        guard let result = try? await runtime.exec(
            containerID: containerName,
            command: [
                "kubectl", "get", "deployment", "dory-amd64-resolver", "-n", "kube-system",
                "-o", "jsonpath={.status.availableReplicas}",
            ]
        ) else { return false }
        return result.exitCode == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func startContainer(_ runtime: any ContainerRuntime, id: String) async throws {
        let encodedID = DockerImageOps.pathComponent(id)
        guard let start = await runtime.proxyRequest(
            method: "POST",
            path: "/containers/\(encodedID)/start",
            headers: [],
            body: Data()
        ) else {
            throw K8sError.createFailed("")
        }
        // Docker returns 304 when another actor won the start race; that is already the desired state.
        guard start.statusCode == 204 || start.statusCode == 304 || start.isSuccess else {
            throw K8sError.createFailed(createFailureDetail(start.body))
        }
    }

    private static func writeKubeconfig(_ runtime: any ContainerRuntime) async throws {
        guard let result = try? await runtime.exec(containerID: containerName, command: ["cat", "/etc/rancher/k3s/k3s.yaml"]),
              result.output.contains("server:") else { throw K8sError.kubeconfigFailed(await startupLogTail(runtime)) }
        // k3s.yaml already targets 127.0.0.1:6443, which the port forwarder makes host-reachable.
        let directory = (kubeconfigPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try result.output.write(toFile: kubeconfigPath, atomically: true, encoding: .utf8)
    }

    private static func deleteExisting(_ runtime: any ContainerRuntime) async {
        let encodedName = DockerImageOps.pathComponent(containerName)
        _ = await runtime.proxyRequest(method: "DELETE", path: "/containers/\(encodedName)?force=true", headers: [], body: Data())
    }

    private static func waitForHostAPI(_ runtime: any ContainerRuntime, progress: @Sendable (String) -> Void) async throws {
        guard let kubectl = HostTools.kubectl() else { throw K8sError.kubectlMissing }
        var lastOutput = ""
        for attempt in 0..<60 {
            if let state = await containerState(runtime), !state.running {
                throw K8sError.containerExited(await startupLogTail(runtime))
            }
            let result = await Shell.runAsyncResult(kubectl, ["--kubeconfig", kubeconfigPath, "get", "--raw", "/version"])
            if result.exit == 0, result.output.contains("gitVersion") {
                return
            }
            lastOutput = result.output
            if attempt == 15 || attempt == 35 {
                progress("Waiting for localhost:\(apiPort) to answer…")
            }
            try? await Task.sleep(for: .seconds(2))
        }
        throw K8sError.apiUnreachable(lastOutput)
    }

    private struct ContainerState: Decodable, Sendable {
        let running: Bool
        let status: String
        let exitCode: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case running = "Running"
            case status = "Status"
            case exitCode = "ExitCode"
            case error = "Error"
        }
    }

    private struct ContainerConfiguration: Decodable, Sendable {
        let Image: String?
        let Labels: [String: String]?
    }

    private struct ContainerInspect: Decodable, Sendable {
        let State: ContainerState?
        let Config: ContainerConfiguration?

        func matches(image: String, amd64Emulation: Bool) -> Bool {
            let labels = Config?.Labels ?? [:]
            return labels[contractLabel] == runtimeContract
                && labels[emulationLabel] == (amd64Emulation ? "fex" : "disabled")
                && labels[imageLabel] == image
                && Config?.Image == image
        }

        func mismatchDetail(image: String, amd64Emulation: Bool) -> String {
            let labels = Config?.Labels ?? [:]
            if labels[contractLabel] != runtimeContract { return "runtime update required" }
            if labels[emulationLabel] != (amd64Emulation ? "fex" : "disabled") { return "amd64 emulation setting changed" }
            if labels[imageLabel] != image || Config?.Image != image { return "Kubernetes image changed" }
            return "container configuration differs"
        }
    }

    private static func containerInspect(_ runtime: any ContainerRuntime) async throws -> ContainerInspect? {
        let encodedName = DockerImageOps.pathComponent(containerName)
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: "/containers/\(encodedName)/json",
            headers: [],
            body: Data()
        ) else {
            throw K8sError.createFailed("could not inspect an existing Kubernetes cluster")
        }
        if response.statusCode == 404 { return nil }
        guard response.isSuccess else { throw K8sError.createFailed(createFailureDetail(response.body)) }
        guard let inspect = try? JSONDecoder().decode(ContainerInspect.self, from: response.body) else {
            throw K8sError.createFailed("the existing Kubernetes container returned an invalid inspection response")
        }
        return inspect
    }

    private static func containerState(_ runtime: any ContainerRuntime) async -> ContainerState? {
        try? await containerInspect(runtime)?.State
    }

    private static func startupLogTail(_ runtime: any ContainerRuntime) async -> String {
        guard let lines = try? await runtime.logs(containerID: containerName) else { return "" }
        return lines.suffix(20).map(\.message).joined(separator: "\n")
    }

    private static func createFailureDetail(_ body: Data?) -> String {
        guard let body, !body.isEmpty else { return "" }
        return String(decoding: body, as: UTF8.self)
    }

    private static func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }
}
