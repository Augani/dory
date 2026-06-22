import Foundation

struct DevRecipe: Identifiable, Hashable, Sendable {
    let id: String
    let display: String
    let icon: String
    let install: String

    static let all: [DevRecipe] = [
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
    ]

    static func forID(_ id: String) -> DevRecipe? { all.first { $0.id == id } }
}
