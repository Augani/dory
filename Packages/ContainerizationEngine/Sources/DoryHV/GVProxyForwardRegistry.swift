import Foundation

package enum GVProxyForwardRegistry {
    package static func publishedForwards(
        from data: Data,
        guestIP: String
    ) -> Set<PublishedPortForward>? {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return nil
        }
        return Set(entries.compactMap { entry in
            guard let protocolValue = PublishedPortForwardProtocol(rawValue: entry.protocol),
                  let local = Endpoint(entry.local),
                  let remote = Endpoint(entry.remote),
                  remote.normalizedHost == Endpoint.normalizedHost(guestIP),
                  local.port == PublishedPortForwardPlan.localPort(forPublishedPort: remote.port) else {
                return nil
            }
            return PublishedPortForward(
                protocol: protocolValue,
                publishedPort: remote.port,
                localHost: local.host,
                localPort: local.port,
                guestHost: guestIP,
                guestPort: remote.port
            )
        })
    }

    private struct Entry: Decodable {
        let local: String
        let remote: String
        let `protocol`: String
    }

    private struct Endpoint {
        let host: String
        let port: Int

        var normalizedHost: String { Self.normalizedHost(host) }

        init?(_ rawValue: String) {
            let value: Substring
            if let scheme = rawValue.range(of: "://") {
                value = rawValue[scheme.upperBound...]
            } else {
                value = rawValue[...]
            }

            let host: Substring
            let portText: Substring
            if value.first == "[" {
                guard let closingBracket = value.firstIndex(of: "]"),
                      value.index(after: closingBracket) < value.endIndex,
                      value[value.index(after: closingBracket)] == ":" else {
                    return nil
                }
                host = value[...closingBracket]
                portText = value[value.index(closingBracket, offsetBy: 2)...]
            } else {
                guard let separator = value.lastIndex(of: ":") else { return nil }
                host = value[..<separator]
                portText = value[value.index(after: separator)...]
            }

            guard !host.isEmpty,
                  let port = Int(portText),
                  (1...65_535).contains(port) else {
                return nil
            }
            self.host = String(host)
            self.port = port
        }

        static func normalizedHost(_ value: String) -> String {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        }
    }
}

package struct GVProxyForwardReconciliation {
    package let observed: Set<PublishedPortForward>
    package let toExpose: Set<PublishedPortForward>
    package let toUnexpose: Set<PublishedPortForward>

    package init(
        wanted: Set<PublishedPortForward>,
        actual: Set<PublishedPortForward>?,
        cached: Set<PublishedPortForward>,
        protected: Set<PublishedPortForward> = []
    ) {
        let current = actual ?? cached
        // Machine-port watcher forwards share gvproxy with Docker publication, but are owned by a
        // separate event stream. Keep them out of Docker's stale-forward cleanup unless Docker also
        // wants the exact same forward.
        observed = current.subtracting(protected.subtracting(wanted))
        toExpose = wanted.subtracting(observed)
        toUnexpose = observed.subtracting(wanted)
    }
}
