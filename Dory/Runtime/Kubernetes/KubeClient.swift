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
