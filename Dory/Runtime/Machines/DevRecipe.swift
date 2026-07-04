import Foundation

struct DevRecipe: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let display: String
    let icon: String
    let install: String
    var summary: String
    var distro: String
    var arch: String
    var resources: Resources
    var packages: [String]
    var runcmd: [String]
    var mounts: [String]
    var ports: [Int]
    var env: [String: String]
    var ssh: SSH
    var docker: Bool
    var user: User

    struct Resources: Hashable, Sendable, Codable {
        var cpus: Int
        var memory: String
        var disk: String
    }

    struct SSH: Hashable, Sendable, Codable {
        var agentForward: Bool
    }

    struct User: Hashable, Sendable, Codable {
        var name: String
        var sudo: Bool
        var shell: String
    }

    enum RecipeError: Error, Equatable, CustomStringConvertible {
        case rootNotMapping
        case unknownKeys([String])
        case missing(String)
        case invalid(String)

        var description: String {
            switch self {
            case .rootNotMapping: "recipe root must be a mapping"
            case .unknownKeys(let keys): "unknown recipe keys: \(keys.joined(separator: ", "))"
            case .missing(let key): "missing required recipe key: \(key)"
            case .invalid(let message): message
            }
        }
    }

    nonisolated init(
        id: String,
        display: String,
        icon: String,
        install: String,
        summary: String = "",
        distro: String = "ubuntu:24.04",
        arch: String = "arm64",
        resources: Resources = Resources(cpus: 2, memory: "4GiB", disk: "40GiB"),
        packages: [String] = [],
        runcmd: [String] = [],
        mounts: [String] = [],
        ports: [Int] = [],
        env: [String: String] = [:],
        ssh: SSH = SSH(agentForward: false),
        docker: Bool = false,
        user: User = User(name: "{{host_user}}", sudo: true, shell: "/bin/bash")
    ) {
        self.id = id
        self.display = display
        self.icon = icon
        self.install = install
        self.summary = summary
        self.distro = distro
        self.arch = arch
        self.resources = resources
        self.packages = packages
        self.runcmd = runcmd
        self.mounts = mounts
        self.ports = ports
        self.env = env
        self.ssh = ssh
        self.docker = docker
        self.user = user
    }

    nonisolated static let all: [DevRecipe] = [
        DevRecipe(id: "node", display: "Node.js", icon: "hexagon",
                  install: "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y nodejs && corepack enable"),
        DevRecipe(id: "python", display: "Python", icon: "chevron.left.forwardslash.chevron.right",
                  install: "apt-get update && apt-get install -y --no-install-recommends python3 python3-pip python3-venv pipx && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "go", display: "Go", icon: "g.circle",
                  install: "ARCH=$(dpkg --print-architecture); curl -fsSL https://go.dev/dl/go1.23.4.linux-${ARCH}.tar.gz | tar -C /usr/local -xz && echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh"),
        DevRecipe(id: "java", display: "Java", icon: "cup.and.saucer",
                  install: "apt-get update && apt-get install -y --no-install-recommends default-jdk maven && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "ruby", display: "Ruby", icon: "diamond",
                  install: "apt-get update && apt-get install -y --no-install-recommends ruby-full build-essential && gem install bundler && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "rust", display: "Rust", icon: "r.circle",
                  install: "apt-get update && apt-get install -y --no-install-recommends rustc cargo && rm -rf /var/lib/apt/lists/*"),
        DevRecipe(id: "devops", display: "DevOps", icon: "shippingbox",
                  install: "apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && ARCH=$(dpkg --print-architecture) && DARCH=$([ \"$ARCH\" = arm64 ] && echo aarch64 || echo x86_64) && curl -fsSL https://download.docker.com/linux/static/stable/$DARCH/docker-27.5.1.tgz | tar -xz -C /tmp && install -m0755 /tmp/docker/docker /usr/local/bin/docker && curl -fsSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$ARCH/kubectl && chmod +x /usr/local/bin/kubectl && rm -rf /var/lib/apt/lists/* /tmp/docker"),
    ]

    nonisolated static func forID(_ id: String) -> DevRecipe? { all.first { $0.id == id } }

    nonisolated static func load(from url: URL) throws -> DevRecipe {
        let yaml = try String(contentsOf: url, encoding: .utf8)
        let root = try YAMLParser.parse(yaml)
        guard let map = root.mappingValue else { throw RecipeError.rootNotMapping }
        let allowed: Set<String> = [
            "name", "summary", "distro", "arch", "resources", "packages", "runcmd",
            "mounts", "ports", "env", "ssh", "docker", "user",
        ]
        let unknown = map.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else { throw RecipeError.unknownKeys(unknown) }
        guard let name = map["name"]?.stringValue, !name.isEmpty else { throw RecipeError.missing("name") }
        guard let distro = map["distro"]?.stringValue, !distro.isEmpty else { throw RecipeError.missing("distro") }

        let resourcesMap = map["resources"]?.mappingValue ?? [:]
        let resources = Resources(
            cpus: resourcesMap["cpus"]?.intValue ?? 2,
            memory: resourcesMap["memory"]?.stringValue ?? "4GiB",
            disk: resourcesMap["disk"]?.stringValue ?? "40GiB"
        )
        let sshMap = map["ssh"]?.mappingValue ?? [:]
        let userMap = map["user"]?.mappingValue ?? [:]
        let recipe = DevRecipe(
            id: name,
            display: name,
            icon: "terminal",
            install: (map["runcmd"]?.stringList ?? []).joined(separator: " && "),
            summary: map["summary"]?.stringValue ?? "",
            distro: distro,
            arch: map["arch"]?.stringValue ?? "arm64",
            resources: resources,
            packages: map["packages"]?.stringList ?? [],
            runcmd: map["runcmd"]?.stringList ?? [],
            mounts: map["mounts"]?.stringList ?? [],
            ports: map["ports"]?.intList ?? [],
            env: map["env"]?.stringMap ?? [:],
            ssh: SSH(agentForward: sshMap["agent_forward"]?.boolValue ?? false),
            docker: map["docker"]?.boolValue ?? false,
            user: User(
                name: userMap["name"]?.stringValue ?? "{{host_user}}",
                sudo: userMap["sudo"]?.boolValue ?? true,
                shell: userMap["shell"]?.stringValue ?? "/bin/bash"
            )
        )
        try recipe.validate()
        return recipe
    }

    nonisolated func validate() throws {
        guard !id.isEmpty else { throw RecipeError.missing("name") }
        guard Self.isDockerNameComponent(id) else {
            throw RecipeError.invalid("name must be a valid image name component: lowercase letters, digits, and separators (. _ -), no spaces, no uppercase, no / or :")
        }
        let parts = distro.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["ubuntu", "debian", "fedora", "alpine", "arch"].contains(parts[0]), !parts[1].isEmpty else {
            throw RecipeError.invalid("distro must be one of ubuntu|debian|fedora|alpine|arch with a tag")
        }
        guard ["arm64", "amd64"].contains(arch) else {
            throw RecipeError.invalid("arch must be arm64 or amd64")
        }
        guard resources.cpus > 0 else { throw RecipeError.invalid("resources.cpus must be positive") }
        guard Self.isSizeString(resources.memory) else { throw RecipeError.invalid("resources.memory must be a size like 8GiB") }
        guard Self.isSizeString(resources.disk) else { throw RecipeError.invalid("resources.disk must be a size like 60GiB") }
        try validateTemplates(in: [summary, distro, arch, resources.memory, resources.disk, user.name, user.shell] + packages + runcmd + mounts + env.flatMap { [$0.key, $0.value] })
    }

    nonisolated func substituted(hostUser: String) -> DevRecipe {
        let guestUser = user.name.replacingOccurrences(of: "{{host_user}}", with: hostUser)
        func sub(_ value: String) -> String {
            value
                .replacingOccurrences(of: "{{host_user}}", with: hostUser)
                .replacingOccurrences(of: "{{user}}", with: guestUser)
        }
        var copy = self
        copy.summary = sub(summary)
        copy.distro = sub(distro)
        copy.arch = sub(arch)
        copy.resources = Resources(cpus: resources.cpus, memory: sub(resources.memory), disk: sub(resources.disk))
        copy.packages = packages.map(sub)
        copy.runcmd = runcmd.map(sub)
        copy.mounts = mounts.map(sub)
        copy.env = Dictionary(uniqueKeysWithValues: env.map { (sub($0.key), sub($0.value)) })
        copy.user = User(name: sub(user.name), sudo: user.sudo, shell: sub(user.shell))
        return copy
    }

    nonisolated func provisionScript(packageManager: MachineDistro.PackageManager) -> String {
        var lines = [String]()
        if !packages.isEmpty {
            lines.append(Self.packageInstall(packages, packageManager: packageManager))
        }
        let commands = runcmd.isEmpty ? (install.isEmpty ? [] : [install]) : runcmd
        lines.append(contentsOf: commands)
        if docker {
            lines.append("install -d -m 755 /var/run/dory")
        }
        return lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    private nonisolated static func packageInstall(_ packages: [String], packageManager: MachineDistro.PackageManager) -> String {
        let names = packages.map(shellQuote).joined(separator: " ")
        switch packageManager {
        case .apt:
            return "apt-get update -qq && apt-get install -y --no-install-recommends \(names) && rm -rf /var/lib/apt/lists/*"
        case .dnf:
            return "dnf install -y \(names) && dnf clean all"
        case .zypper:
            return "zypper --non-interactive --gpg-auto-import-keys refresh && zypper -n install \(names) && zypper clean -a"
        case .apk:
            return "apk add --no-cache \(names)"
        case .pacman:
            return "pacman -Sy --noconfirm --needed \(names)"
        }
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func isSizeString(_ value: String) -> Bool {
        let pattern = #"^[1-9][0-9]*(MiB|GiB|TiB)$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private nonisolated static func isDockerNameComponent(_ value: String) -> Bool {
        let pattern = #"^[a-z0-9]+((\.|_|__|-+)[a-z0-9]+)*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private nonisolated func validateTemplates(in values: [String]) throws {
        for value in values {
            var search = value.startIndex..<value.endIndex
            while let open = value.range(of: "{{", range: search) {
                guard let close = value.range(of: "}}", range: open.upperBound..<value.endIndex) else {
                    throw RecipeError.invalid("unterminated template variable in \(value)")
                }
                let variable = value[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                guard ["user", "host_user"].contains(variable) else {
                    throw RecipeError.invalid("unknown template variable \(variable)")
                }
                search = close.upperBound..<value.endIndex
            }
        }
    }
}

private extension YAMLValue {
    nonisolated var intValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        case .tagged(_, let inner): inner.intValue
        default: nil
        }
    }

    nonisolated var intList: [Int] {
        switch self {
        case .sequence(let items): items.compactMap(\.intValue)
        case .number, .string: intValue.map { [$0] } ?? []
        case .tagged(_, let inner): inner.intList
        default: []
        }
    }

    nonisolated var stringMap: [String: String] {
        guard let mappingValue else { return [:] }
        return Dictionary(uniqueKeysWithValues: mappingValue.compactMap { key, value in
            value.stringValue.map { (key, $0) }
        })
    }
}
