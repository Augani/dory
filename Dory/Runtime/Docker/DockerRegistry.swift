import Foundation

/// Registry server normalization, image-reference parsing, and `~/.docker/config.json` auth
/// persistence — the Docker registry/credential helpers shared by the engine runtime and the
/// Apple-container runtime.
enum DockerRegistry {
    static func normalizeRegistry(_ r: String) -> String {
        let t = r.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "docker.io" || t == "index.docker.io" || t == "registry-1.docker.io" {
            return "https://index.docker.io/v1/"
        }
        return t
    }

    static func registryServer(for repo: String) -> String {
        if let slash = repo.firstIndex(of: "/") {
            let first = String(repo[repo.startIndex..<slash])
            if first.contains(".") || first.contains(":") || first == "localhost" { return first }
        }
        return "https://index.docker.io/v1/"
    }

    static func persistDockerAuth(server: String, username: String, password: String) {
        let dir = NSHomeDirectory() + "/.docker"
        let path = dir + "/config.json"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var config: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { config = obj }
        var auths = config["auths"] as? [String: Any] ?? [:]
        auths[server] = ["auth": Data("\(username):\(password)".utf8).base64EncodedString()]
        config["auths"] = auths
        if let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: path))
        }
    }

    static func registryAuthHeader(for repo: String) -> String? {
        let server = registryServer(for: repo)
        let path = NSHomeDirectory() + "/.docker/config.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auths = obj["auths"] as? [String: Any],
              let entry = auths[server] as? [String: Any], let b64 = entry["auth"] as? String,
              let decoded = Data(base64Encoded: b64), let creds = String(data: decoded, encoding: .utf8) else { return nil }
        let parts = creds.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let json = try? JSONSerialization.data(withJSONObject: [
                  "username": String(parts[0]), "password": String(parts[1]), "serveraddress": server]) else { return nil }
        return json.base64EncodedString()
    }

    static func splitImageRef(_ image: String) -> (repo: String, tag: String) {
        // A digest pin (`repo@sha256:…`) must be preserved — Docker's /images/create accepts the
        // digest in the `tag` query slot. Substituting `latest` would pull a different image.
        if let at = image.range(of: "@") {
            return (String(image[image.startIndex..<at.lowerBound]), String(image[at.upperBound...]))
        }
        // A colon after the last slash is the tag separator.
        if let colon = image.lastIndex(of: ":"), let slash = image.lastIndex(of: "/"), colon > slash {
            return (String(image[image.startIndex..<colon]), String(image[image.index(after: colon)...]))
        }
        if let colon = image.lastIndex(of: ":"), !image.contains("/") {
            return (String(image[image.startIndex..<colon]), String(image[image.index(after: colon)...]))
        }
        return (image, "latest")
    }
}
