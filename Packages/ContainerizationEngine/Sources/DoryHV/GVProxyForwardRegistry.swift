import Darwin
import Foundation

package struct GVProxyForwardRegistry: Sendable, Equatable {
    package struct Entry: Sendable, Hashable {
        package let `protocol`: PublishedPortForwardProtocol
        package let local: Endpoint
        package let remote: Endpoint

        fileprivate func publishedForward(guestIP: String) -> PublishedPortForward? {
            guard remote.normalizedHost == Endpoint.normalizedHost(guestIP),
                  local.isIPAddress,
                  local.port == PublishedPortForwardPlan.localPort(forPublishedPort: remote.port) else {
                return nil
            }
            return PublishedPortForward(
                protocol: `protocol`,
                publishedPort: remote.port,
                localHost: local.forwardHost,
                localPort: local.port,
                guestHost: guestIP,
                guestPort: remote.port
            )
        }

        fileprivate func hasSameLocalEndpoint(as forward: PublishedPortForward) -> Bool {
            `protocol` == forward.protocol
                && local.port == forward.localPort
                && local.normalizedHost == Endpoint.normalizedHost(forward.localHost)
        }

        fileprivate func matches(_ forward: PublishedPortForward) -> Bool {
            hasSameLocalEndpoint(as: forward)
                && remote.port == forward.guestPort
                && remote.normalizedHost == Endpoint.normalizedHost(forward.guestHost)
        }
    }

    package struct Endpoint: Sendable, Hashable {
        package let host: String
        package let port: Int

        package var normalizedHost: String { Self.normalizedHost(host) }
        fileprivate var forwardHost: String {
            let unbracketed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return unbracketed.contains(":") ? "[\(unbracketed)]" : unbracketed
        }

        fileprivate var isIPAddress: Bool {
            if normalizedHost.contains(":") {
                let pieces = normalizedHost.split(
                    separator: "%",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                guard !pieces[0].isEmpty,
                      pieces.count == 1 || (!pieces[1].isEmpty && pieces[1].allSatisfy({
                          $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
                      })) else {
                    return false
                }
                var address = in6_addr()
                return String(pieces[0]).withCString { inet_pton(AF_INET6, $0, &address) } == 1
            }
            var address = in_addr()
            return normalizedHost.withCString { inet_pton(AF_INET, $0, &address) } == 1
        }

        package init?(_ rawValue: String) {
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

            guard let port = Int(portText),
                  (1...65_535).contains(port) else {
                return nil
            }
            self.host = String(host)
            self.port = port
        }

        package static func normalizedHost(_ value: String) -> String {
            value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        }
    }

    package let entries: Set<Entry>

    package init(entries: Set<Entry>) {
        self.entries = entries
    }

    package static func decode(_ data: Data) -> GVProxyForwardRegistry? {
        guard let decoded = try? JSONDecoder().decode([DecodedEntry].self, from: data) else {
            return nil
        }
        var entries = Set<Entry>()
        for entry in decoded {
            guard let protocolValue = PublishedPortForwardProtocol(
                rawValue: entry.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ) else {
                // Unix infrastructure forwards share this registry but are outside Docker port
                // ownership and often have non-IP local endpoints.
                continue
            }
            guard let local = Endpoint(entry.local), let remote = Endpoint(entry.remote) else {
                // Never validate a partial TCP/UDP registry: a dropped malformed row could conceal
                // a conflicting key and turn a repair into a false success.
                return nil
            }
            entries.insert(Entry(protocol: protocolValue, local: local, remote: remote))
        }
        return GVProxyForwardRegistry(entries: entries)
    }

    package func publishedForwards(guestIP: String) -> Set<PublishedPortForward> {
        Set(entries.compactMap { $0.publishedForward(guestIP: guestIP) })
    }

    /// Returns desired identities whose gvproxy `(protocol, local)` key is occupied by a different
    /// remote. gvproxy cannot expose the desired entry until that conflicting key is unexposed.
    package func conflictingWantedForwards(
        _ wanted: Set<PublishedPortForward>
    ) -> Set<PublishedPortForward> {
        Set(wanted.filter { forward in
            entries.contains { entry in
                entry.hasSameLocalEndpoint(as: forward) && !entry.matches(forward)
            }
        })
    }

    private struct DecodedEntry: Decodable {
        let local: String
        let remote: String
        let `protocol`: String
    }
}

package struct GVProxyForwardReconciliation {
    package let observed: Set<PublishedPortForward>
    package let toExpose: Set<PublishedPortForward>
    package let toUnexpose: Set<PublishedPortForward>

    package init(
        wanted: Set<PublishedPortForward>,
        actual: GVProxyForwardRegistry?,
        cached: Set<PublishedPortForward>,
        protected: Set<PublishedPortForward> = [],
        guestIP: String
    ) {
        let current = actual?.publishedForwards(guestIP: guestIP) ?? cached
        // Machine-port watcher forwards share gvproxy with Docker publication, but are owned by a
        // separate event stream. Keep them out of Docker's orphan cleanup unless Docker wants the
        // exact same forward too.
        observed = current.subtracting(protected.subtracting(wanted))
        let conflicts = actual?.conflictingWantedForwards(wanted) ?? []
        toUnexpose = observed.subtracting(wanted).union(conflicts)
        toExpose = wanted.subtracting(observed).union(conflicts)
    }
}
