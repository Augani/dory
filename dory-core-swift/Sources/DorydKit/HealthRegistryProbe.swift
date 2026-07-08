import Darwin
import Foundation

public protocol HealthRegistryProbing: Sendable {
    func checks(host: String, port: Int, name: String, defaultProbe: Bool) -> [HealthCheck]
}

public final class URLSessionHealthRegistryProbe: HealthRegistryProbing, @unchecked Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public func checks(host: String, port: Int, name: String, defaultProbe: Bool) -> [HealthCheck] {
        let slug = slugify(name.isEmpty ? host : name)
        let dnsID = defaultProbe ? "network.registry_dns" : "network.registry_dns.\(slug)"
        let httpsID = defaultProbe ? "network.registry_https" : "network.registry_https.\(slug)"
        let tcpID = defaultProbe ? "network.registry_tcp" : "network.registry_tcp.\(slug)"
        let probeData = ["probe": "\(host):\(port)"]

        let resolved = resolve(host: host, port: port)
        switch resolved {
        case let .failure(message):
            return [
                HealthCheck(
                    id: dnsID,
                    status: .fail,
                    code: "network.registry_dns_failed",
                    title: "Host cannot resolve network probe",
                    detail: "\(host):\(port): \(message)",
                    action: "Check DNS, VPN, or proxy settings.",
                    data: probeData
                ),
            ]
        case let .success(addresses):
            var checks = [
                HealthCheck(
                    id: dnsID,
                    status: .pass,
                    code: "network.registry_dns_ok",
                    title: "Host resolves network probe",
                    detail: "\(host):\(port)",
                    data: probeData.merging(["ips": addresses.prefix(8).joined(separator: ",")]) { _, rhs in rhs }
                ),
            ]

            checks.append(httpsCheck(host: host, port: port, httpsID: httpsID, tcpID: tcpID, probeData: probeData))
            return checks
        }
    }

    private func httpsCheck(host: String, port: Int, httpsID: String, tcpID: String, probeData: [String: String]) -> HealthCheck {
        guard let url = URL(string: "https://\(host):\(port)/v2/") else {
            return HealthCheck(
                id: tcpID,
                status: .fail,
                code: "network.registry_tcp_failed",
                title: "Network probe TCP connection failed",
                detail: "invalid registry probe URL",
                data: probeData
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue("doryd-health", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = RegistryProbeResponse()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseBox.store(
                status: (response as? HTTPURLResponse)?.statusCode,
                body: data.map { String(decoding: $0.prefix(512), as: UTF8.self) } ?? "",
                error: error
            )
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
            return HealthCheck(
                id: tcpID,
                status: .fail,
                code: "network.registry_timeout",
                title: "Network probe connection timed out",
                detail: "timed out after \(timeout)s",
                data: probeData
            )
        }

        let (status, text, error) = responseBox.snapshot()

        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorServerCertificateUntrusted
                || nsError.code == NSURLErrorSecureConnectionFailed
                || nsError.code == NSURLErrorClientCertificateRejected
                || nsError.code == NSURLErrorClientCertificateRequired {
                return HealthCheck(
                    id: httpsID,
                    status: .fail,
                    code: "network.registry_tls_failed",
                    title: "Network probe TLS failed",
                    detail: error.localizedDescription,
                    data: probeData
                )
            }
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                return HealthCheck(
                    id: tcpID,
                    status: .fail,
                    code: "network.registry_timeout",
                    title: "Network probe connection timed out",
                    detail: error.localizedDescription,
                    data: probeData
                )
            }
            return HealthCheck(
                id: tcpID,
                status: .fail,
                code: "network.registry_tcp_failed",
                title: "Network probe TCP connection failed",
                detail: error.localizedDescription,
                data: probeData
            )
        }

        guard let status else {
            return HealthCheck(
                id: tcpID,
                status: .fail,
                code: "network.registry_tcp_failed",
                title: "Network probe TCP connection failed",
                detail: "empty response",
                data: probeData
            )
        }
        if status == 200 || status == 401 {
            return HealthCheck(
                id: httpsID,
                status: .pass,
                code: "network.registry_https_ok",
                title: "Network probe HTTPS path works",
                detail: "HTTP \(status); auth challenge is expected for Docker Hub",
                data: probeData
            )
        }
        return HealthCheck(
            id: httpsID,
            status: .warn,
            code: "network.registry_unexpected_status",
            title: "Network probe returned unexpected status",
            detail: "HTTP \(status): \(String(text.prefix(120)))",
            data: probeData
        )
    }
}

private enum ResolveResult {
    case success([String])
    case failure(String)
}

private final class RegistryProbeResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int?
    private var body = ""
    private var error: Error?

    func store(status: Int?, body: String, error: Error?) {
        lock.lock()
        self.status = status
        self.body = body
        self.error = error
        lock.unlock()
    }

    func snapshot() -> (Int?, String, Error?) {
        lock.lock()
        let value = (status, body, error)
        lock.unlock()
        return value
    }
}

private func resolve(host: String, port: Int) -> ResolveResult {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, String(port), &hints, &result)
    guard rc == 0, let result else {
        return .failure(String(cString: gai_strerror(rc)))
    }
    defer { freeaddrinfo(result) }

    var addresses = Set<String>()
    var current: UnsafeMutablePointer<addrinfo>? = result
    while let pointer = current {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(
            pointer.pointee.ai_addr,
            pointer.pointee.ai_addrlen,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        ) == 0 {
            let length = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
            let bytes = hostBuffer.prefix(length).map { UInt8(bitPattern: $0) }
            addresses.insert(String(decoding: bytes, as: UTF8.self))
        }
        current = pointer.pointee.ai_next
    }
    return .success(addresses.sorted())
}

private func slugify(_ value: String) -> String {
    let scalars = value.lowercased().unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
    }
    let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
    return collapsed.isEmpty ? "probe" : collapsed
}
