import Foundation

nonisolated protocol RegistryImageSearch: Sendable {
    func search(term: String, limit: Int?) async throws -> [DockerImageSearchOut]
}

struct HubImageSearch: RegistryImageSearch {
    var timeout: TimeInterval = 5

    func search(term: String, limit: Int?) async throws -> [DockerImageSearchOut] {
        var request = URLRequest(url: Self.searchURL(term: term, limit: limit), timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HubImageSearchError.unexpectedStatus
        }
        return try JSONDecoder().decode(HubSearchResponse.self, from: data).results.map(\.dockerSearchOut)
    }

    static func searchURL(term: String, limit: Int?) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "index.docker.io"
        components.path = "/v1/search"
        var items = [URLQueryItem(name: "q", value: term)]
        if let limit, limit > 0 { items.append(URLQueryItem(name: "n", value: String(limit))) }
        components.queryItems = items
        return components.url ?? URL(string: "https://index.docker.io/v1/search")!
    }
}

enum HubImageSearchError: Error {
    case unexpectedStatus
}

private struct HubSearchResponse: Decodable {
    let results: [HubSearchResult]
}

private struct HubSearchResult: Decodable {
    let name: String
    let description: String?
    let is_official: Bool?
    let is_automated: Bool?
    let star_count: Int?

    var dockerSearchOut: DockerImageSearchOut {
        DockerImageSearchOut(
            description: description ?? "",
            is_official: is_official ?? false,
            is_automated: is_automated ?? false,
            name: name,
            star_count: star_count ?? 0
        )
    }
}
