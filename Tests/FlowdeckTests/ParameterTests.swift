import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import Flowdeck

func parameters(_ json: String) throws -> PlacementParameters {
    try JSONDecoder().decode(PlacementParameters.self, from: Data(json.utf8))
}

@Test func parameterTypesDefaultsAndRoundTrip() throws {
    let values = try parameters(#"{"ask_review":false,"title":"","delay":0,"fraction":1.25,"text_bool":"true","one":1}"#)
    #expect(!values.bool("ask_review", default: true))
    #expect(values.string("title", default: "Welcome") == "")
    #expect(values.number("delay", default: 10) == 0)
    #expect(values.number("fraction", default: 0) == 1.25)
    #expect(values.bool("missing", default: true))
    #expect(values.string("missing", default: "fallback") == "fallback")
    #expect(values.number("missing", default: 4) == 4)
    #expect(!values.bool("text_bool", default: false))
    #expect(!values.bool("one", default: false))
    #expect(values.number("ask_review", default: 4) == 4)
    #expect(values.string("one", default: "fallback") == "fallback")
    #expect(try JSONDecoder().decode(PlacementParameters.self, from: JSONEncoder().encode(values)) == values)
}

@Test(arguments: [#"{"key":null}"#, #"{"key":[]}"#, #"{"key":{}}"#, "null", "[]"])
func invalidParameterValuesAreRejected(json: String) {
    #expect(throws: (any Error).self) { try parameters(json) }
}

@Test func legacyManifestAndReadyCacheWithoutParametersStillLoad() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip()
    var wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(placement(bytes))) as? [String: Any])
    wire.removeValue(forKey: "parameters")
    let legacy = try JSONSerialization.data(withJSONObject: wire)
    let decoded = try JSONDecoder().decode(Placement.self, from: legacy)
    #expect(decoded.parameters == PlacementParameters())
    let configuration = FlowdeckConfiguration(apiKey: "key", baseURL: URL(string: "https://example.com")!, cacheDirectory: directory)
    let repository = try ContentRepository(configuration: configuration, transport: StubTransport([.offline]))
    let cache = await repository.cache
    _ = try cache.store(bytes, hash: decoded.hash)
    try legacy.write(to: cache.root.appendingPathComponent("ready-paywall.json"))
    #expect(try await repository.resolve("paywall").parameters == PlacementParameters())
    let snapshot = try JSONSerialization.data(withJSONObject: [
        "manifest": ["app_id": "test", "placements": [wire]], "etag": "legacy"
    ])
    try snapshot.write(to: cache.root.appendingPathComponent("manifest.json"))
    let restarted = try ContentRepository(configuration: configuration, transport: StubTransport([
        .response(.init(data: Data(), status: 304, etag: "legacy"))
    ]))
    #expect(try await restarted.resolve("paywall").parameters == PlacementParameters())
}

@Test func parametersRefreshWithoutPackageChangeAndPersistOffline() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = try zip()
    let original = try parameters(#"{"ask_review":true,"headline":"Welcome"}"#)
    let changed = try parameters(#"{"ask_review":false,"delay":1.5}"#)
    let transport = StubTransport([
        .response(try manifestResponse([placement(bytes, parameters: original)])),
        .response(.init(data: bytes, status: 200, etag: nil)),
        .response(try manifestResponse([placement(bytes, parameters: changed)], etag: "v2")),
        .response(.init(data: Data(), status: 304, etag: "v2"))
    ])
    let configuration = FlowdeckConfiguration(apiKey: "key", baseURL: URL(string: "https://example.com")!, cacheDirectory: directory)
    let repository = try ContentRepository(configuration: configuration, transport: transport)
    #expect(try await repository.resolve("paywall").parameters == original)
    #expect(try await repository.refresh().first?.parameters == changed)
    let cached = try await repository.resolve("paywall")
    #expect(cached.source == .cache)
    #expect(cached.parameters == changed)
    #expect(cached.parameters.string("headline", default: "removed") == "removed")
    let requests = await transport.requests
    #expect(requests.filter { $0.url?.path.hasPrefix("/v1/sdk/packages/") == true }.count == 1)
    #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == "v2")
    let restarted = try ContentRepository(configuration: configuration, transport: StubTransport([.offline]))
    #expect(try await restarted.resolve("paywall").parameters == changed)
    // The last-ready descriptor also retains parameters if the manifest is lost.
    let cache = await repository.cache
    try FileManager.default.removeItem(at: cache.root.appendingPathComponent("manifest.json"))
    #expect(try await restarted.resolve("paywall").parameters == changed)
}

@Test func currentParametersFollowOldAndBundledPackageFallbacks() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = try zip(), new = try zip([("index.html", "New")])
    let values = try parameters(#"{"ask_review":false}"#)
    let configuration = FlowdeckConfiguration(apiKey: "key", baseURL: URL(string: "https://example.com")!, cacheDirectory: directory)
    let repository = try ContentRepository(configuration: configuration, transport: StubTransport([
        .response(try manifestResponse([placement(old)])), .response(.init(data: old, status: 200, etag: nil)),
        .response(try manifestResponse([placement(new, version: 2, parameters: values)])), .offline
    ]))
    let initial = try await repository.resolve("paywall")
    let fallback = try await repository.resolve("paywall")
    #expect(fallback.indexURL == initial.indexURL)
    #expect(fallback.parameters == values)
    let bundle = directory.appendingPathComponent("bundle.zip")
    try old.write(to: bundle)
    let bundledRepository = try ContentRepository(configuration: .init(apiKey: "other", baseURL: configuration.baseURL,
        fallbackPackages: [.init(placementID: "paywall", kind: .paywall, zipURL: bundle, sha256: PackageCache.hash(old))],
        cacheDirectory: directory), transport: StubTransport([
            .offline, .response(try manifestResponse([placement(new, parameters: values)])), .offline
        ]))
    #expect(try await bundledRepository.resolve("paywall").parameters == PlacementParameters())
    let bundled = try await bundledRepository.resolve("paywall")
    #expect(bundled.source == .bundled)
    #expect(bundled.parameters == values)
}

@MainActor @Test func parameterBridgeReturnsPresentationValues() async throws {
    let values = try parameters(#"{"ask_review":false,"title":"Hello","delay":2.5}"#)
    let content = FlowdeckContent(placementID: "onboarding", kind: .onboarding, productIDs: [],
        indexURL: URL(fileURLWithPath: "/package/index.html"), source: .cache, fallbackReason: nil, parameters: values)
    let router = BridgeRouter(content: content, commerce: FakeCommerce(), emit: { _ in }, review: {}, openURL: { _ in false })
    let message = try BridgeMessage.parse(Data(#"{"id":"1","method":"getParameters","params":{}}"#.utf8))
    let response = await router.handle(message)
    #expect(response.error == nil)
    #expect(response.result == (try JSONValue.encoded(values)))
    #expect(throws: FlowdeckError.self) {
        try BridgeMessage.parse(Data(#"{"id":"1","method":"getParameters","params":{"placement":"other"}}"#.utf8))
    }
}

@MainActor @Test func parameterScriptIsSafeAvailableBeforePageCodeAndReadOnly() throws {
    let text = "quotes '\" backslash \\ newline\n </script> \u{2028}\u{2029} Türkçe 🚀 ; window.injected = true; //"
    let json = try JSONEncoder().encode(["headline": JSONValue.string(text), "ask_review": .bool(false),
                                         "delay": .number(1.25), "__proto__": .string("ordinary key")])
    let values = try JSONDecoder().decode(PlacementParameters.self, from: json)
    for expected in [values, PlacementParameters()] {
        let script = try BridgeScript.userScript(parameters: expected)
        #expect(script.injectionTime == .atDocumentStart)
        #expect(script.isForMainFrameOnly)
        let context = try #require(JSContext())
        context.evaluateScript("var window = this; window.top = window;")
        context.evaluateScript(script.source)
        #expect(context.exception == nil)
        let serialized = try #require(context.evaluateScript("JSON.stringify(window.flowdeck.parameters)")?.toString())
        #expect(try parameters(serialized) == expected)
        #expect(context.evaluateScript("typeof window.flowdeck.getParameters")?.toString() == "function")
        #expect(context.evaluateScript("Object.isFrozen(window.flowdeck.parameters)")?.toBool() == true)
        #expect(context.evaluateScript("typeof window.injected")?.toString() == "undefined")
        context.evaluateScript("window.flowdeck.parameters = {}; window.flowdeck.parameters.ask_review = true;")
        let afterMutation = try #require(context.evaluateScript("JSON.stringify(window.flowdeck.parameters)")?.toString())
        #expect(afterMutation == serialized)
    }
}
