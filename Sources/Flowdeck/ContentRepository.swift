import Foundation

struct HTTPResponse: Sendable {
    let data: Data
    let status: Int
    let etag: String?
}
protocol HTTPTransport: Sendable {
    func get(_ request: URLRequest) async throws -> HTTPResponse
}

/// Redirects are rejected so an API credential cannot leave the configured origin.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    init(protocolClasses: [URLProtocol.Type] = []) {
        let configuration = URLSessionConfiguration.ephemeral
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    func get(_ request: URLRequest) async throws -> HTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw FlowdeckError.invalidResponse }
        guard http.expectedContentLength <= PackageCache.maxZIPSize else { throw FlowdeckError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < PackageCache.maxZIPSize else { throw FlowdeckError.invalidResponse }
            data.append(byte)
        }
        return HTTPResponse(data: data, status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}

actor ContentRepository {
    private struct Snapshot: Codable, Sendable {
        let manifest: Manifest
        let etag: String?
    }
    private let configuration: FlowdeckConfiguration
    private let transport: any HTTPTransport
    let cache: PackageCache
    private var refreshTask: Task<Manifest, Error>?

    init(configuration: FlowdeckConfiguration, transport: (any HTTPTransport)? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        self.transport = transport ?? URLSessionTransport(protocolClasses: configuration.protocolClasses)
        let namespace = PackageCache.hash(Data((configuration.baseURL.absoluteString + "\n" + configuration.apiKey).utf8))
        cache = PackageCache(root: configuration.cacheDirectory.appendingPathComponent(namespace))
    }

    private var snapshotURL: URL { cache.root.appendingPathComponent("manifest.json") }
    private func snapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let value = try? JSONDecoder().decode(Snapshot.self, from: data),
              (try? value.manifest.validate()) != nil else { return nil }
        return value
    }

    private func request(_ path: String, etag: String? = nil) -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(String(path.dropFirst())),
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        return request
    }

    func refresh() async throws -> [Placement] { try await manifest().placements }

    private func manifest() async throws -> Manifest {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await fetchManifest() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func fetchManifest() async throws -> Manifest {
        let previous = snapshot()
        let response = try await transport.get(request("/v1/sdk/placements", etag: previous?.etag))
        if response.status == 304 {
            guard let previous else { throw FlowdeckError.invalidResponse }
            return previous.manifest
        }
        guard response.status == 200 else { throw FlowdeckError.httpStatus(response.status) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: response.data)
        try manifest.validate()
        try FileManager.default.createDirectory(at: cache.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Snapshot(manifest: manifest, etag: response.etag))
            .write(to: snapshotURL, options: .atomic)
        return manifest
    }

    func resolve(_ id: String) async throws -> FlowdeckContent {
        guard Placement.validID(id) else { throw FlowdeckError.placementNotFound(id) }
        let current: Manifest
        do {
            current = try await manifest()
        } catch {
            try Task.checkCancellation()
            return try bundledFallback(id, failure: error)
        }
        guard let placement = current.placements.first(where: { $0.id == id }) else {
            throw FlowdeckError.placementNotFound(id)
        }
        return FlowdeckContent(placementID: id, kind: placement.kind, productIDs: placement.productIDs,
            indexURL: try LivePage.url(baseURL: configuration.baseURL, appID: current.appID, placementID: id),
            source: .network, fallbackReason: nil, parameters: placement.parameters)
    }

    func fallback(for content: FlowdeckContent, failure: any Error) throws -> FlowdeckContent {
        guard content.source == .network else { throw failure }
        return try loadBundle(content.placementID, failure: failure, parameters: content.parameters)
    }

    private func bundledFallback(_ id: String, failure: any Error) throws -> FlowdeckContent {
        let previous = snapshot()?.manifest
        let placement = previous?.placements.first(where: { $0.id == id })
        if previous != nil, placement == nil { throw FlowdeckError.placementNotFound(id) }
        return try loadBundle(id, failure: failure, parameters: placement?.parameters ?? .init())
    }

    private func loadBundle(_ id: String, failure: any Error, parameters: PlacementParameters) throws -> FlowdeckContent {
        guard let fallback = configuration.fallbackPackages.first(where: { $0.placementID == id }) else {
            throw failure
        }
        let bytes = try Data(contentsOf: fallback.zipURL, options: .mappedIfSafe)
        let index = try cache.store(bytes, hash: fallback.sha256)
        return FlowdeckContent(placementID: id, kind: fallback.kind, productIDs: fallback.productIDs,
            indexURL: index, source: .bundled, fallbackReason: failure.localizedDescription,
            parameters: parameters)
    }
}
