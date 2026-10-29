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
        var failure: Error?
        var online = false
        let current: Manifest?
        do {
            current = try await manifest()
            online = true
        } catch {
            try Task.checkCancellation()
            failure = error
            current = snapshot()?.manifest
        }
        let placement = current?.placements.first(where: { $0.id == id })
        if let placement {
            do {
                if let index = try? cache.cached(placement.hash) {
                    try remember(placement)
                    return content(placement, index, .cache, failure)
                }
                if online {
                    let response = try await transport.get(request(placement.url))
                    guard response.status == 200 else { throw FlowdeckError.httpStatus(response.status) }
                    guard response.data.count == placement.size else { throw FlowdeckError.invalidPackage }
                    let index = try cache.store(response.data, hash: placement.hash)
                    try remember(placement)
                    return content(placement, index, .network, nil)
                }
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        } else if current != nil {
            // An explicit unpublish/removal is authoritative; don't revive a retired placement.
            throw FlowdeckError.placementNotFound(id)
        }
        let readyURL = cache.root.appendingPathComponent("ready-\(id).json")
        if let data = try? Data(contentsOf: readyURL),
           let ready = try? JSONDecoder().decode(Placement.self, from: data), ready.id == id,
           (try? ready.validate()) != nil, let index = try? cache.cached(ready.hash) {
            return content(ready, index, .cache, failure, parameters: placement?.parameters)
        }
        if let fallback = configuration.fallbackPackages.first(where: { $0.placementID == id }) {
            let bytes = try Data(contentsOf: fallback.zipURL, options: .mappedIfSafe)
            let index = try cache.store(bytes, hash: fallback.sha256)
            return FlowdeckContent(placementID: id, kind: fallback.kind, productIDs: fallback.productIDs,
                                   indexURL: index, source: .bundled, fallbackReason: failure?.localizedDescription,
                                   parameters: placement?.parameters ?? .init())
        }
        throw failure ?? FlowdeckError.placementNotFound(id)
    }

    private func remember(_ placement: Placement) throws {
        try JSONEncoder().encode(placement).write(
            to: cache.root.appendingPathComponent("ready-\(placement.id).json"), options: .atomic)
    }
    private func content(_ placement: Placement, _ index: URL, _ source: FlowdeckContent.Source,
                         _ failure: Error?, parameters: PlacementParameters? = nil) -> FlowdeckContent {
        FlowdeckContent(placementID: placement.id, kind: placement.kind, productIDs: placement.productIDs,
                        indexURL: index, source: source, fallbackReason: failure?.localizedDescription,
                        parameters: parameters ?? placement.parameters)
    }
}
