import Foundation
import Testing
import ZIPFoundation
@testable import Flowdeck

func temporaryDirectory() throws -> URL {
    let root = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    let url = root.appendingPathComponent("FlowdeckTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func zip(_ files: [(String, String)] = [("index.html", "<h1>Flowdeck</h1>")]) throws -> Data {
    let archive = try Archive(accessMode: .create)
    for (path, string) in files {
        let data = Data(string.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
            data.subdata(in: Int(position)..<(Int(position) + count))
        }
    }
    return try #require(archive.data)
}

func placement(_ bytes: Data, version: Int = 1, parameters: PlacementParameters = .init()) -> Placement {
    let hash = PackageCache.hash(bytes)
    return Placement(id: "paywall", kind: .paywall, version: version, hash: hash, size: bytes.count,
                     url: "/v1/sdk/packages/\(hash)", productIDs: ["pro.weekly"], publishedAt: "2026-10-25T00:00:00Z",
                     parameters: parameters)
}
func manifestResponse(_ placements: [Placement], etag: String = "\"v1\"") throws -> HTTPResponse {
    HTTPResponse(data: try JSONEncoder().encode(Manifest(appID: "test", placements: placements)), status: 200, etag: etag)
}

actor StubTransport: HTTPTransport {
    enum Result: Sendable { case response(HTTPResponse), offline }
    private var results: [Result]
    private let delay: Duration
    private(set) var requests: [URLRequest] = []
    init(_ results: [Result], delay: Duration = .zero) { self.results = results; self.delay = delay }
    func get(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        guard !results.isEmpty else { throw URLError(.notConnectedToInternet) }
        switch results.removeFirst() {
        case .response(let response): return response
        case .offline: throw URLError(.notConnectedToInternet)
        }
    }
}

@Test func etagDiskCacheAndOfflineAcrossInstances() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip()
    let transport = StubTransport([
        .response(try manifestResponse([placement(bytes)])),
        .response(HTTPResponse(data: bytes, status: 200, etag: nil)),
        .response(HTTPResponse(data: Data(), status: 304, etag: "\"v1\""))
    ])
    let config = FlowdeckConfiguration(apiKey: "test-key", baseURL: URL(string: "https://example.com")!, cacheDirectory: directory)
    let first = try ContentRepository(configuration: config, transport: transport)
    let downloaded = try await first.resolve("paywall")
    #expect(downloaded.source == .network)
    #expect(try String(contentsOf: downloaded.indexURL, encoding: .utf8) == "<h1>Flowdeck</h1>")
    let cached = try await first.resolve("paywall")
    #expect(cached.source == .cache)
    let requests = await transport.requests
    #expect(requests.count == 3)
    #expect(requests[0].url?.path == "/v1/sdk/placements")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    #expect(requests[2].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    let restarted = try ContentRepository(configuration: config, transport: StubTransport([.offline]))
    let offline = try await restarted.resolve("paywall")
    #expect(offline.source == .cache)
    #expect(offline.fallbackReason != nil)
}

@Test func badUpdateKeepsLastUsablePackage() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = try zip(), new = try zip([("index.html", "New version")])
    let transport = StubTransport([
        .response(try manifestResponse([placement(old)])), .response(.init(data: old, status: 200, etag: nil)),
        .response(try manifestResponse([placement(new, version: 2)], etag: "\"v2\"")),
        .response(.init(data: Data(repeating: 0, count: new.count), status: 200, etag: nil)),
        .offline
    ])
    let repo = try ContentRepository(configuration: .init(apiKey: "key", baseURL: URL(string: "https://example.com")!,
                                                          cacheDirectory: directory), transport: transport)
    let original = try await repo.resolve("paywall")
    let fallback = try await repo.resolve("paywall")
    #expect(fallback.indexURL == original.indexURL)
    #expect(fallback.source == .cache)
    #expect(fallback.fallbackReason == FlowdeckError.hashMismatch.localizedDescription)
    let offline = try await repo.resolve("paywall")
    #expect(offline.indexURL == original.indexURL)
}

@Test func bundledFallbackAndHashVerification() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip()
    let bundle = directory.appendingPathComponent("fallback.zip")
    try bytes.write(to: bundle)
    let fallback = FlowdeckFallbackPackage(placementID: "paywall", kind: .paywall,
        zipURL: bundle, sha256: PackageCache.hash(bytes), productIDs: ["pro.weekly"])
    let repo = try ContentRepository(configuration: .init(apiKey: "key", baseURL: URL(string: "https://example.com")!,
        fallbackPackages: [fallback], cacheDirectory: directory), transport: StubTransport([.offline, .offline]))
    #expect(try await repo.resolve("paywall").source == .bundled)
    try Data("tampered".utf8).write(to: bundle)
    await #expect(throws: FlowdeckError.self) { try await repo.resolve("paywall") }
}

@Test func removedPlacementIsNotResurrected() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip()
    let transport = StubTransport([
        .response(try manifestResponse([placement(bytes)])), .response(.init(data: bytes, status: 200, etag: nil)),
        .response(try manifestResponse([], etag: "\"removed\""))
    ])
    let repo = try ContentRepository(configuration: .init(apiKey: "key", baseURL: URL(string: "https://example.com")!,
                                                          cacheDirectory: directory), transport: transport)
    _ = try await repo.resolve("paywall")
    await #expect(throws: FlowdeckError.self) { try await repo.resolve("paywall") }
    // Once removed, an offline restart must not resurrect the ready descriptor.
    await #expect(throws: FlowdeckError.self) { try await repo.resolve("paywall") }
}

@Test func cacheNamespaceSeparatesCredentialsAndOrigin() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip()
    let repo = try ContentRepository(configuration: .init(apiKey: "one", baseURL: URL(string: "https://example.com")!,
        cacheDirectory: directory), transport: StubTransport([.response(try manifestResponse([placement(bytes)])),
                                                             .response(.init(data: bytes, status: 200, etag: nil))]))
    _ = try await repo.resolve("paywall")
    for (key, origin) in [("two", "https://example.com"), ("one", "https://other.example.com")] {
        let other = try ContentRepository(configuration: .init(apiKey: key, baseURL: URL(string: origin)!, cacheDirectory: directory),
                                          transport: StubTransport([.offline]))
        await #expect(throws: (any Error).self) { try await other.resolve("paywall") }
    }
}

@Test func corruptExtractionIsRepairedAndCorruptArchiveRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = PackageCache(root: directory)
    let bytes = try zip([("index.html", "Original"), ("assets/style.css", "body {}")])
    let hash = PackageCache.hash(bytes)
    let index = try cache.store(bytes, hash: hash)
    try Data("tampered".utf8).write(to: index)
    let repaired = try cache.cached(hash)
    #expect(try String(contentsOf: repaired, encoding: .utf8) == "Original")
    try Data("tampered".utf8).write(to: cache.archiveURL(hash))
    #expect(throws: FlowdeckError.self) { try cache.cached(hash) }
}

@Test(arguments: ["../escape", "/absolute", "a/../../escape", "a\\escape", "a:escape", "a//b", "a/./b", "index.HTML"])
func unsafeArchivePathsAreRejected(path: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip([("index.html", "Valid"), (path, "Invalid")])
    #expect(throws: (any Error).self) { try PackageCache(root: directory).store(bytes, hash: PackageCache.hash(bytes)) }
}

@Test func missingIndexAndSymlinksAreRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = PackageCache(root: directory)
    let missing = try zip([("other.html", "Hello")])
    #expect(throws: FlowdeckError.self) { try cache.store(missing, hash: PackageCache.hash(missing)) }
    let archive = try Archive(accessMode: .create)
    let target = Data("../escape".utf8)
    try archive.addEntry(with: "index.html", type: .symlink, uncompressedSize: Int64(target.count)) { offset, size in
        target.subdata(in: Int(offset)..<(Int(offset) + size))
    }
    let bytes = try #require(archive.data)
    #expect(throws: FlowdeckError.self) { try cache.store(bytes, hash: PackageCache.hash(bytes)) }
}

@Test func invalidManifestCannotRedirectCredentials() throws {
    let bytes = try zip()
    let p = placement(bytes)
    let invalid = Placement(id: p.id, kind: p.kind, version: 1, hash: p.hash, size: p.size,
                            url: "https://other.example.com/steal", productIDs: [], publishedAt: "")
    #expect(throws: FlowdeckError.self) { try invalid.validate() }
    #expect(throws: FlowdeckError.self) {
        try FlowdeckConfiguration(apiKey: "key", baseURL: URL(string: "http://example.com")!).validate()
    }
}

@Test func concurrentManifestRefreshesShareOneRequest() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip()
    let transport = StubTransport([.response(try manifestResponse([placement(bytes)]))], delay: .milliseconds(50))
    let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: URL(string: "https://example.com")!,
        cacheDirectory: directory), transport: transport)
    async let first = repository.refresh()
    async let second = repository.refresh()
    let values = try await (first, second)
    #expect(values.0 == values.1)
    #expect(await transport.requests.count == 1)
}

@Test func unexpected304WithoutPersistedManifestFails() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: URL(string: "https://example.com")!,
        cacheDirectory: directory), transport: StubTransport([.response(.init(data: Data(), status: 304, etag: "\"x\""))]))
    await #expect(throws: FlowdeckError.self) { try await repository.resolve("paywall") }
}

@Test func corruptDiskZIPUsesBundleThenRecoversFromNetwork() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let remote = try zip([("index.html", "Remote")])
    let embedded = try zip([("index.html", "Bundled")])
    let bundle = directory.appendingPathComponent("fallback.zip")
    try embedded.write(to: bundle)
    let transport = StubTransport([
        .response(try manifestResponse([placement(remote)])), .response(.init(data: remote, status: 200, etag: nil)),
        .offline,
        .response(.init(data: Data(), status: 304, etag: "\"v1\"")), .response(.init(data: remote, status: 200, etag: nil))
    ])
    let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: URL(string: "https://example.com")!,
        fallbackPackages: [.init(placementID: "paywall", kind: .paywall, zipURL: bundle, sha256: PackageCache.hash(embedded))],
        cacheDirectory: directory), transport: transport)
    _ = try await repository.resolve("paywall")
    let cache = await repository.cache
    try Data("corrupted".utf8).write(to: cache.archiveURL(PackageCache.hash(remote)))
    #expect(try await repository.resolve("paywall").source == .bundled)
    let recovered = try await repository.resolve("paywall")
    #expect(recovered.source == .network)
    #expect(try String(contentsOf: recovered.indexURL, encoding: .utf8) == "Remote")
}

@Test func tooManyArchiveFilesAreRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = [("index.html", "Index")] + (0..<500).map { ("\($0).txt", "x") }
    let bytes = try zip(files)
    #expect(throws: FlowdeckError.self) { try PackageCache(root: directory).store(bytes, hash: PackageCache.hash(bytes)) }
}

@Test func serverWireFormatAndGoZIPInteroperate() async throws {
    // Generated with Go archive/zip's CreateHeader, the server's normalizer format
    // (deflate + data descriptors), independently of the SDK's ZIP library.
    let bytes = try #require(Data(base64Encoded: "UEsDBBQACAAIAAAAAAAAAAAAAAAAAAAAAAAKAAAAaW5kZXguaHRtbAAPAPD/PGgxPkdvIFpJUDwvaDE+AwBQSwcIcicfXxYAAAAPAAAAUEsDBBQACAAIAAAAAAAAAAAAAAAAAAAAAAAQAAAAYXNzZXRzL3N0eWxlLmNzcwATAOz/aDEgeyBjb2xvcjogYmx1ZTsgfQMAUEsHCL/KDE0aAAAAEwAAAFBLAQIUABQACAAIAAAAAAByJx9fFgAAAA8AAAAKAAAAAAAAAAAAAAAAAAAAAABpbmRleC5odG1sUEsBAhQAFAAIAAgAAAAAAL/KDE0aAAAAEwAAABAAAAAAAAAAAAAAAAAATgAAAGFzc2V0cy9zdHlsZS5jc3NQSwUGAAAAAAIAAgB2AAAApgAAAAAA"))
    let wire = Data(#"{"app_id":"test","placements":[{"id":"paywall","kind":"paywall","version":3,"hash":"6b7f2044ba1b6d045a1359eeef8dff2bd7de47a202bef3243ad81a2306a74bd4","size":306,"url":"/v1/sdk/packages/6b7f2044ba1b6d045a1359eeef8dff2bd7de47a202bef3243ad81a2306a74bd4","product_ids":["pro.weekly"],"published_at":"2026-10-25T09:12:44Z"}]}"#.utf8)
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: URL(string: "https://example.com")!,
        cacheDirectory: directory), transport: StubTransport([
            .response(.init(data: wire, status: 200, etag: "\"server\"")),
            .response(.init(data: bytes, status: 200, etag: nil))
        ]))
    let content = try await repository.resolve("paywall")
    #expect(content.productIDs == ["pro.weekly"])
    #expect(try String(contentsOf: content.indexURL, encoding: .utf8) == "<h1>Go ZIP</h1>")
    #expect(try String(contentsOf: content.indexURL.deletingLastPathComponent().appendingPathComponent("assets/style.css"),
                       encoding: .utf8) == "h1 { color: blue; }")
}
