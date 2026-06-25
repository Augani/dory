import Foundation

nonisolated struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [(name: String, value: String)] = []
    var body: Data?
}

nonisolated struct HTTPResponse: Sendable {
    var statusCode: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

nonisolated enum HTTPError: Error, Sendable, Equatable {
    case malformedStatusLine
    case incomplete
    case malformedChunk
    case connectionClosed
    case socket(String)
    case status(code: Int, message: String)
}

/// Incrementally strips HTTP chunked-transfer framing from a byte stream, emitting payload bytes.
nonisolated final class ChunkedStreamDecoder: @unchecked Sendable {
    private var buffer = [UInt8]()

    func feed(_ data: Data) -> Data {
        buffer.append(contentsOf: data)
        var output = Data()
        while true {
            guard let lineEnd = indexOfCRLF(from: 0) else { break }
            let sizeText = String(bytes: buffer[0..<lineEnd], encoding: .utf8) ?? ""
            let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0, size <= HTTPCodec.maxChunkBytes else { buffer.removeAll(keepingCapacity: false); break }
            let dataStart = lineEnd + 2
            if size == 0 { buffer.removeAll(keepingCapacity: false); break }
            guard buffer.count - dataStart >= size + 2 else { break }
            output.append(contentsOf: buffer[dataStart..<dataStart + size])
            buffer.removeFirst(dataStart + size + 2)
        }
        return output
    }

    private func indexOfCRLF(from start: Int) -> Int? {
        var i = start
        while i + 1 < buffer.count {
            if buffer[i] == 13, buffer[i + 1] == 10 { return i }
            i += 1
        }
        return nil
    }
}

nonisolated struct ParsedRequest: Sendable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    var queryItems: [(key: String, value: String)] {
        guard let q = target.split(separator: "?", maxSplits: 1).dropFirst().first else { return [] }
        return q.split(separator: "&").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let rawKey = kv.first else { return nil }
            let key = Self.decodeQueryComponent(rawKey)
            let value = kv.count > 1 ? Self.decodeQueryComponent(kv[1]) : ""
            return (key, value)
        }
    }

    var query: [String: String] {
        var result: [String: String] = [:]
        for item in queryItems { result[item.key] = item.value }
        return result
    }

    func queryValues(for key: String) -> [String] {
        queryItems.compactMap { $0.key == key ? $0.value : nil }
    }

    private static func decodeQueryComponent(_ raw: Substring) -> String {
        let formDecoded = String(raw).replacingOccurrences(of: "+", with: " ")
        return formDecoded.removingPercentEncoding ?? formDecoded
    }
}

nonisolated enum HTTPCodec {
    static let crlf = Data([13, 10])
    static let headerTerminator = Data([13, 10, 13, 10])
    static let maxChunkBytes = 512 * 1024 * 1024

    nonisolated static func parseRequest(_ data: Data) throws -> ParsedRequest? {
        guard let headerEnd = range(of: headerTerminator, in: data) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { throw HTTPError.malformedStatusLine }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPError.malformedStatusLine }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { throw HTTPError.malformedStatusLine }
        let method = String(requestLine[0])
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerEnd.upperBound
        let available = data.subdata(in: bodyStart..<data.endIndex)
        if let lengthString = headers["content-length"], let length = Int(lengthString), length > 0 {
            guard available.count >= length else { return nil }
            let body = available.subdata(in: available.startIndex..<available.index(available.startIndex, offsetBy: length))
            return ParsedRequest(method: method, target: target, headers: headers, body: body)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = try decodeChunked(available) else { return nil }
            return ParsedRequest(method: method, target: target, headers: headers, body: body)
        }
        return ParsedRequest(method: method, target: target, headers: headers, body: Data())
    }

    nonisolated static func serializeResponse(status: Int, headers: [(name: String, value: String)] = [], body: Data) -> Data {
        var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        var allHeaders = headers
        if !allHeaders.contains(where: { $0.name.lowercased() == "content-length" }) {
            allHeaders.append((name: "Content-Length", value: String(body.count)))
        }
        if !allHeaders.contains(where: { $0.name.lowercased() == "connection" }) {
            allHeaders.append((name: "Connection", value: "close"))
        }
        for header in allHeaders { text += "\(header.name): \(header.value)\r\n" }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    nonisolated static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }

    nonisolated static func serialize(_ request: HTTPRequest, host: String = "dory") -> Data {
        var lines = "\(request.method) \(request.path) HTTP/1.1\r\n"
        var headers = request.headers
        if !headers.contains(where: { $0.name.lowercased() == "host" }) {
            headers.insert((name: "Host", value: host), at: 0)
        }
        if let body = request.body, !headers.contains(where: { $0.name.lowercased() == "content-length" }) {
            headers.append((name: "Content-Length", value: String(body.count)))
        }
        if !headers.contains(where: { $0.name.lowercased() == "connection" }) {
            headers.append((name: "Connection", value: "close"))
        }
        for header in headers { lines += "\(header.name): \(header.value)\r\n" }
        lines += "\r\n"
        var data = Data(lines.utf8)
        if let body = request.body { data.append(body) }
        return data
    }

    nonisolated static func serializeChunkedRequest(_ request: HTTPRequest, host: String = "dory") -> Data {
        var lines = "\(request.method) \(request.path) HTTP/1.1\r\n"
        var headers = request.headers.filter {
            let name = $0.name.lowercased()
            return name != "content-length" && name != "transfer-encoding"
        }
        if !headers.contains(where: { $0.name.lowercased() == "host" }) {
            headers.insert((name: "Host", value: host), at: 0)
        }
        headers.append((name: "Transfer-Encoding", value: "chunked"))
        if !headers.contains(where: { $0.name.lowercased() == "connection" }) {
            headers.append((name: "Connection", value: "close"))
        }
        for header in headers { lines += "\(header.name): \(header.value)\r\n" }
        lines += "\r\n"
        return Data(lines.utf8)
    }

    /// Parse a complete HTTP response from `data`. Returns nil if more bytes are required.
    /// When `connectionClosed` is true, a response without Content-Length or chunked encoding is
    /// finalized using whatever body has arrived (the only way to delimit such a response).
    nonisolated static func parseResponse(_ data: Data, connectionClosed: Bool = false) throws -> HTTPResponse? {
        guard let headerEnd = range(of: headerTerminator, in: data) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { throw HTTPError.malformedStatusLine }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPError.malformedStatusLine }
        let statusLine = lines.removeFirst()
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2, let code = Int(statusParts[1]) else { throw HTTPError.malformedStatusLine }
        let reason = statusParts.count >= 3 ? String(statusParts[2]) : ""

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let remaining = data.subdata(in: bodyStart..<data.endIndex)

        if let lengthString = headers["content-length"], let length = Int(lengthString), length >= 0 {
            guard remaining.count >= length else { return nil }
            let body = remaining.subdata(in: remaining.startIndex..<remaining.index(remaining.startIndex, offsetBy: length))
            return HTTPResponse(statusCode: code, reason: reason, headers: headers, body: body)
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = try decodeChunked(remaining) else { return nil }
            return HTTPResponse(statusCode: code, reason: reason, headers: headers, body: body)
        }

        // No length and not chunked: the response is delimited by connection close, so we must
        // keep reading until EOF rather than returning a possibly-truncated body.
        guard connectionClosed else { return nil }
        return HTTPResponse(statusCode: code, reason: reason, headers: headers, body: remaining)
    }

    /// Decode a complete chunked body. Returns nil if the terminating chunk has not yet arrived.
    nonisolated static func decodeChunked(_ data: Data) throws -> Data? {
        var output = Data()
        var index = data.startIndex
        while true {
            guard let lineEnd = range(of: crlf, in: data, from: index) else { return nil }
            let sizeLine = data.subdata(in: index..<lineEnd.lowerBound)
            guard let sizeText = String(data: sizeLine, encoding: .utf8) else { throw HTTPError.malformedChunk }
            let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0, size <= maxChunkBytes else { throw HTTPError.malformedChunk }
            let chunkStart = lineEnd.upperBound
            if size == 0 { return output }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            output.append(data.subdata(in: chunkStart..<chunkEnd))
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }

    nonisolated static func range(of pattern: Data, in data: Data, from: Data.Index? = nil) -> Range<Data.Index>? {
        let start = from ?? data.startIndex
        guard !pattern.isEmpty, data.distance(from: start, to: data.endIndex) >= pattern.count else { return nil }
        var i = start
        let last = data.index(data.endIndex, offsetBy: -pattern.count)
        while i <= last {
            if data[i..<data.index(i, offsetBy: pattern.count)].elementsEqual(pattern) {
                return i..<data.index(i, offsetBy: pattern.count)
            }
            i = data.index(after: i)
        }
        return nil
    }
}
