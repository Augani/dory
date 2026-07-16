import Testing
import Foundation
import ServiceManagement
#if canImport(Darwin)
import Darwin
#endif
@testable import Dory

@Suite(.serialized)
struct NetworkingTests {
    private func dnsQuery(name: String, qtype: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00)
        packet.append(contentsOf: [0x00, qtype, 0x00, 0x01])
        return packet
    }

    @Test func dnsAnswersDomainSuffixWithLoopback() throws {
        let query = dnsQuery(name: "myapp.dory.local", qtype: 1)
        let response = try #require(DoryDNS.makeResponse(query, suffix: "dory.local", ip: "127.0.0.1"))
        #expect(response[0] == 0x12 && response[1] == 0x34)          // echoed ID
        #expect(response[2] & 0x80 != 0)                              // QR = response
        #expect(response[7] == 0x01)                                  // ANCOUNT = 1
        #expect(Array(response.suffix(4)) == [127, 0, 0, 1])          // A record RDATA
    }

    @Test func dnsUsesExactHostOverrideForMachines() throws {
        let query = dnsQuery(name: "dev.dory.local", qtype: 1)
        let response = try #require(DoryDNS.makeResponse(
            query,
            suffix: "dory.local",
            ip: "127.0.0.1",
            hostIPs: ["dev.dory.local": "172.17.0.5"]
        ))
        #expect(response[7] == 0x01)
        #expect(Array(response.suffix(4)) == [172, 17, 0, 5])

        let fallback = try #require(DoryDNS.makeResponse(
            dnsQuery(name: "web.dory.local", qtype: 1),
            suffix: "dory.local",
            ip: "127.0.0.1",
            hostIPs: ["dev.dory.local": "172.17.0.5"]
        ))
        #expect(Array(fallback.suffix(4)) == [127, 0, 0, 1])
    }

    @Test func dnsRefusesForeignDomains() {
        #expect(DoryDNS.makeResponse(dnsQuery(name: "google.com", qtype: 1), suffix: "dory.local", ip: "127.0.0.1") == nil)
    }

    @Test func dnsReturnsNoAnswerForAAAA() throws {
        let response = try #require(DoryDNS.makeResponse(dnsQuery(name: "myapp.dory.local", qtype: 28), suffix: "dory.local", ip: "127.0.0.1"))
        #expect(response[7] == 0x00)                                  // ANCOUNT = 0 (we only serve A)
    }

    @Test func reverseProxyExtractsHost() {
        let request = Data("GET /path HTTP/1.1\r\nHost: MyApp.dory.local:8080\r\nAccept: */*\r\n\r\n".utf8)
        #expect(DoryReverseProxy.hostHeader(request) == "myapp.dory.local")
    }

    @Test func reverseProxyMissingHostIsNil() {
        let request = Data("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n".utf8)
        #expect(DoryReverseProxy.hostHeader(request) == nil)
    }

    @Test func domainTableRoutesToLoopbackPort() {
        let table = DomainTable()
        table.replaceContainers(["myapp.dory.local": 8091])
        let backend = table.backend(for: "MyApp.dory.local")
        #expect(backend?.host == "127.0.0.1")
        #expect(backend?.port == 8091)
        #expect(backend?.pathPrefix == "")
        #expect(table.backend(for: "other.dory.local") == nil)
    }

    @Test func domainTableRoutesKubeServices() {
        let table = DomainTable()
        table.replaceKube(["web.default.k8s.dory.local": ProxyBackend(host: "127.0.0.1", port: 18001, pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy")])
        let backend = table.backend(for: "web.default.k8s.dory.local")
        #expect(backend?.port == 18001)
        #expect(backend?.pathPrefix.contains("services/web:80/proxy") == true)
    }

    @Test func machineDNSHostsIncludeOnlyRunningMachinesWithIPv4() {
        let machines = [
            Machine(name: "dev", distro: "Ubuntu", version: "24.04", status: .running, cpuPercent: 0, memoryDisplay: "0", ip: "172.17.0.5", letter: "U", badgeHex: 0),
            Machine(name: "off", distro: "Ubuntu", version: "24.04", status: .stopped, cpuPercent: 0, memoryDisplay: "0", ip: "172.17.0.6", letter: "U", badgeHex: 0),
            Machine(name: "pending", distro: "Ubuntu", version: "24.04", status: .running, cpuPercent: 0, memoryDisplay: "0", ip: "—", letter: "U", badgeHex: 0),
        ]
        #expect(AppStore.machineDNSHosts(machines, suffix: "dory.local") == ["dev.dory.local": "172.17.0.5"])
    }

    @Test func lowPublishedPortsUseHighLoopbackBackends() {
        #expect(AppStore.effectivePublishedPort(80) == 60_080)
        #expect(AppStore.effectivePublishedPort(443) == 60_443)
        #expect(AppStore.effectivePublishedPort(1024) == 1024)
    }

    @Test func networkingAuthorizationSummaryListsDorydLowPortRedirects() {
        let plan = DorydNetworkingAuthorizationPlan(
            degradedMode: "high-port-dns-only",
            authorizedMode: "system-resolver-proxy-tls",
            suffix: "dory.local",
            dnsBindAddress: "127.0.0.1",
            dnsPort: 15353,
            httpProxyPort: 8080,
            httpsProxyPort: 8443,
            privilegedTCPForwards: [
                DorydPrivilegedTCPForward(listenPort: 25, targetPort: 60_025),
                DorydPrivilegedTCPForward(listenPort: 110, targetPort: 60_110),
            ],
            requests: []
        )

        #expect(AppStore.networkingAuthorizationSummary(plan) == "Standard 80/443 plus low TCP redirects: 25 -> 60025, 110 -> 60110.")
    }

    @Test func networkingAuthorizationSummaryHandlesNoExtraLowPorts() {
        let plan = DorydNetworkingAuthorizationPlan(
            degradedMode: "high-port-dns-only",
            authorizedMode: "system-resolver-proxy-tls",
            suffix: "dory.local",
            dnsBindAddress: "127.0.0.1",
            dnsPort: 15353,
            httpProxyPort: 8080,
            httpsProxyPort: 8443,
            requests: []
        )

        #expect(AppStore.networkingAuthorizationSummary(plan).contains("no extra low TCP publishes"))
    }

    @Test func networkingAuthorizationSuccessDoesNotFailOnPendingBackgroundApproval() {
        let plan = DorydNetworkingAuthorizationPlan(
            degradedMode: "high-port-dns-only",
            authorizedMode: "system-resolver-proxy-tls",
            suffix: "dory.local",
            dnsBindAddress: "127.0.0.1",
            dnsPort: 15353,
            httpProxyPort: 8080,
            httpsProxyPort: 8443,
            requests: []
        )

        let message = AppStore.networkingAuthorizationSuccessMessage(
            plan,
            removing: false,
            backgroundServiceNotice: "Approve Dory's networking service in System Settings."
        )
        #expect(message.hasPrefix("Dory networking is authorized for dory.local."))
        #expect(message.contains("Background updates need attention"))
        #expect(message.contains("System Settings"))
    }

    @Test func networkingDeauthorizationDoesNotDependOnBackgroundService() {
        let plan = DorydNetworkingAuthorizationPlan(
            degradedMode: "high-port-dns-only",
            authorizedMode: "system-resolver-proxy-tls",
            suffix: "dory.local",
            dnsBindAddress: "127.0.0.1",
            dnsPort: 15353,
            httpProxyPort: 8080,
            httpsProxyPort: 8443,
            requests: []
        )

        #expect(
            AppStore.networkingAuthorizationSuccessMessage(
                plan,
                removing: true,
                backgroundServiceNotice: "ignored"
            ) == "Dory-owned resolver, PF reference, and local CA trust were removed for dory.local."
        )
    }

    @Test func missingServiceManagementRecordStillTriggersRegistration() {
        #expect(AppStore.privilegedNetworkDaemonNeedsRegistration(.notRegistered))
        #expect(AppStore.privilegedNetworkDaemonNeedsRegistration(.notFound))
        #expect(!AppStore.privilegedNetworkDaemonNeedsRegistration(.enabled))
        #expect(!AppStore.privilegedNetworkDaemonNeedsRegistration(.requiresApproval))
    }

    @Test func domainSuffixNormalizationAcceptsDNSStyleSuffixes() {
        #expect(AppStore.normalizedDomainSuffix(" Team.Dory.Local. ") == "team.dory.local")
        #expect(AppStore.normalizedDomainSuffix("dory.local") == "dory.local")
    }

    @Test func domainSuffixNormalizationRejectsUnsafeSuffixes() {
        #expect(AppStore.normalizedDomainSuffix("dory") == nil)
        #expect(AppStore.normalizedDomainSuffix("-team.dory.local") == nil)
        #expect(AppStore.normalizedDomainSuffix("team..dory.local") == nil)
        #expect(AppStore.normalizedDomainSuffix("team_dory.local") == nil)
        #expect(AppStore.normalizedDomainSuffix("team dory.local") == nil)
    }

    @Test func kubeServiceProxyBuildsStableServiceRoutes() {
        #expect(KubeServiceProxy.serviceHost(name: "Web", namespace: "Default", suffix: "dory.local") == "web.default.k8s.dory.local")
        #expect(KubeServiceProxy.serviceProxyPath(name: "web", namespace: "default", port: 8080) == "/api/v1/namespaces/default/services/web:8080/proxy")
        #expect(KubeServiceProxy.firstPort(from: "8080/TCP, 8443/TCP") == 8080)
    }

    @Test func kubeServiceBrowserURLFallsBackToKubectlProxy() throws {
        let domainURL = try #require(KubeServiceProxy.browserURL(
            name: "web",
            namespace: "default",
            ports: "80/TCP",
            suffix: "dory.local",
            domainAvailable: true
        ))
        #expect(domainURL.absoluteString == "http://web.default.k8s.dory.local")

        let proxyURL = try #require(KubeServiceProxy.browserURL(
            name: "web",
            namespace: "default",
            ports: "80/TCP",
            suffix: "dory.local",
            domainAvailable: false
        ))
        #expect(proxyURL.absoluteString == "http://127.0.0.1:18001/api/v1/namespaces/default/services/web:80/proxy/")
    }

    @Test func rewriteRequestPrependsPathPrefix() {
        let request = Data("GET /healthz HTTP/1.1\r\nHost: web.default.k8s.dory.local\r\n\r\n".utf8)
        let rewritten = DoryReverseProxy.rewriteRequest(request, pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy")
        let text = String(data: rewritten, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("GET /api/v1/namespaces/default/services/web:80/proxy/healthz HTTP/1.1\r\n"))
        #expect(text.contains("Host: web.default.k8s.dory.local"))
    }

    @Test func volumeBrowserParsesListing() {
        let output = """
        total 8
        drwxr-xr-x    2 root     root          4096 2026-06-18 11:31:05 +0000 logs
        -rw-r--r--    1 root     root            23 2026-06-18 11:31:05 +0000 readme.txt
        """
        let entries = VolumeBrowser.parseListing(output)
        #expect(entries.count == 2)
        #expect(entries.first?.name == "logs")          // directories sort first
        #expect(entries.first?.isDirectory == true)
        #expect(entries.last?.name == "readme.txt")
        #expect(entries.last?.isDirectory == false)
    }

    @Test func volumeBrowserPathIsSandboxed() {
        #expect(VolumeBrowser.safePath("../../etc/passwd") == "/data/etc/passwd")
        #expect(VolumeBrowser.safePath("/logs/app.log") == "/data/logs/app.log")
        #expect(VolumeBrowser.safePath("") == "/data/")
    }

    @Test func unixSocketHTTPHonorsIOTimeoutWhenPeerHangs() async throws {
        let path = Self.shortSocketPath("dory-hung")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 0.05)

        do {
            _ = try await client.send(HTTPRequest(method: "GET", path: "/version"))
            Issue.record("expected hung socket to time out")
        } catch let error as HTTPError {
            guard case .socket(let message) = error else {
                Issue.record("expected socket error, got \(error)")
                return
            }
            #expect(message.contains("read"))
        } catch {
            Issue.record("expected HTTPError, got \(error)")
        }
    }

    @Test func cancellingRequestClosesHungSocketPromptly() async throws {
        let path = Self.shortSocketPath("dory-cancel-hung")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 5)
        let request = Task {
            try await client.send(HTTPRequest(method: "GET", path: "/version"))
        }

        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        request.cancel()
        do {
            _ = try await request.value
            Issue.record("expected cancelled request to fail")
        } catch {
            // Closing the descriptor can surface CancellationError, connectionClosed, or EBADF;
            // the contract is that cancellation is prompt rather than waiting for the idle timer.
        }
        #expect(cancelledAt.duration(to: ContinuousClock.now) < .seconds(1))
    }

    @Test func chunkedUploadHonorsIOTimeoutWhenPeerNeverResponds() async throws {
        let path = Self.shortSocketPath("dory-hung-chunked")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 0.05)
        let body = AsyncStream<Data> { continuation in
            continuation.yield(Data("archive".utf8))
            continuation.finish()
        }

        do {
            _ = try await client.sendChunked(
                HTTPRequest(method: "POST", path: "/images/load"),
                body: body
            )
            Issue.record("expected hung chunked upload to time out")
        } catch let error as HTTPError {
            guard case .socket(let message) = error else {
                Issue.record("expected socket error, got \(error)")
                return
            }
            #expect(message.contains("read"))
        } catch {
            Issue.record("expected HTTPError, got \(error)")
        }
    }

    @Test func chunkedUploadPropagatesSourceArchiveFailureWithoutCompletingRequest() async throws {
        let path = Self.shortSocketPath("dory-failed-chunked-source")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 1)
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("partial-archive".utf8))
            continuation.finish(throwing: ArchiveStreamFixtureError.sourceReadFailed)
        }

        do {
            _ = try await client.sendChunked(
                HTTPRequest(method: "PUT", path: "/containers/helper/archive?path=%2Fdata"),
                body: body
            )
            Issue.record("expected source archive failure")
        } catch let error as ArchiveStreamFixtureError {
            #expect(error == .sourceReadFailed)
        } catch {
            Issue.record("expected the source archive error, got \(error)")
        }
    }

    @Test func successfulStreamReportsIdleTimeoutInsteadOfHangingForever() async throws {
        let path = Self.shortSocketPath("dory-hung-stream")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 0.05)

        let completion: Result<Void, Error> = await withCheckedContinuation { continuation in
            _ = client.streamSuccessful(
                HTTPRequest(method: "GET", path: "/images/example/get"),
                onChunk: { _ in },
                onComplete: { continuation.resume(returning: $0) }
            )
        }
        switch completion {
        case .success:
            Issue.record("expected hung stream to report an idle timeout")
        case .failure(let error as HTTPError):
            guard case .socket(let message) = error else {
                Issue.record("expected socket error, got \(error)")
                return
            }
            #expect(message.contains("read"))
        case .failure(let error):
            Issue.record("expected HTTPError, got \(error)")
        }
    }

    @Test func demandDrivenBodyStreamReportsIdleTimeout() async throws {
        let path = Self.shortSocketPath("dory-hung-pull-stream")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 0.05)
        var iterator = client.successfulBodyStream(
            HTTPRequest(method: "GET", path: "/images/example/get")
        ).makeAsyncIterator()

        do {
            _ = try await iterator.next()
            Issue.record("expected demand-driven stream to time out")
        } catch let error as HTTPError {
            guard case .socket(let message) = error else {
                Issue.record("expected socket error, got \(error)")
                return
            }
            #expect(message.contains("read"))
        } catch {
            Issue.record("expected HTTPError, got \(error)")
        }
    }

    @Test func cancellingDemandDrivenBodyReadClosesHungSocketPromptly() async throws {
        let path = Self.shortSocketPath("dory-cancel-pull-stream")
        let server = try HangingUnixSocket(path: path)
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path, ioTimeout: 5)
        let read = Task {
            var iterator = client.successfulBodyStream(
                HTTPRequest(method: "GET", path: "/containers/helper/archive")
            ).makeAsyncIterator()
            return try await iterator.next()
        }

        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        read.cancel()
        do {
            _ = try await read.value
            Issue.record("expected cancelled demand-driven read to fail")
        } catch {
            // Cancellation closes the descriptor and may surface cancellation, EBADF, or EOF.
        }
        #expect(cancelledAt.duration(to: ContinuousClock.now) < .seconds(1))
    }

    private static func shortSocketPath(_ prefix: String) -> String {
        let path = "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock"
        try? FileManager.default.removeItem(atPath: path)
        return path
    }
}

private enum ArchiveStreamFixtureError: Error, Equatable {
    case sourceReadFailed
}

private final class HangingUnixSocket {
    private let path: String
    private let fd: Int32
    private let accepted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var clientFD: Int32 = -1

    init(path: String) throws {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("socket")) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw HTTPError.socket("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { dst in
                for (i, byte) in bytes.enumerated() { dst[i] = byte }
                dst[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("bind")) }
        guard listen(fd, 1) == 0 else { throw HTTPError.socket(UnixSocketHTTP.errnoMessage("listen")) }
        Thread.detachNewThread { [fd, accepted, weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            self?.lock.lock()
            self?.clientFD = client
            self?.lock.unlock()
            accepted.signal()
            Thread.sleep(forTimeInterval: 2)
            self?.lock.lock()
            if self?.clientFD == client {
                self?.clientFD = -1
                Darwin.close(client)
            }
            self?.lock.unlock()
        }
    }

    func stop() {
        Darwin.close(fd)
        lock.lock()
        let client = clientFD
        clientFD = -1
        lock.unlock()
        if client >= 0 { Darwin.close(client) }
        try? FileManager.default.removeItem(atPath: path)
    }
}
