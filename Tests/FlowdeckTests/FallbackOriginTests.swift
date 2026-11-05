import Foundation
import JavaScriptCore
import XCTest
@testable import Flowdeck

final class FallbackOriginTests: XCTestCase {
    private let primary = URL(string: "https://flowdeck.proxy.example")!
    private let backups = [URL(string: "https://api.flowdeck.example")!, URL(string: "https://backup.flowdeck.example")!]

    func testLiveFailuresTryFallbackOriginsInOrderThenBundleThenError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try zip()
        let bundle = directory.appendingPathComponent("paywall.zip")
        try bytes.write(to: bundle)
        let values = try parameters(#"{"ask_review":false}"#)
        let transport = StubTransport([.response(try manifestResponse([placement(Data("x".utf8), parameters: values)]))])
        let repository = try ContentRepository(configuration: .init(apiKey: "secret", baseURL: primary,
            fallbackPackages: [.init(placementID: "paywall", kind: .paywall, zipURL: bundle,
                                     sha256: PackageCache.hash(bytes), productIDs: ["bundled.product"])],
            cacheDirectory: directory, fallbackOrigins: backups), transport: transport)
        let live = try await repository.resolve("paywall")
        XCTAssertEqual(live.indexURL.absoluteString, "https://flowdeck.proxy.example/live/test/paywall/")
        XCTAssertNil(live.fallbackReason)

        let first = try await repository.fallback(for: live, failure: FlowdeckError.httpStatus(503))
        XCTAssertEqual(first.indexURL.absoluteString, "https://api.flowdeck.example/live/test/paywall/")
        XCTAssertEqual(first.source, .network)
        XCTAssertEqual(first.fallbackReason, FlowdeckError.httpStatus(503).localizedDescription)
        XCTAssertEqual(first.parameters, values)
        XCTAssertEqual(first.productIDs, ["pro.weekly"], "Placement metadata comes from the manifest, not the origin")
        XCTAssertEqual(first.kind, .paywall)

        let second = try await repository.fallback(for: first, failure: URLError(.timedOut))
        XCTAssertEqual(second.indexURL.absoluteString, "https://backup.flowdeck.example/live/test/paywall/")
        XCTAssertEqual(second.source, .network)

        let bundled = try await repository.fallback(for: second, failure: URLError(.cannotConnectToHost))
        XCTAssertEqual(bundled.source, .bundled)
        XCTAssertEqual(bundled.productIDs, ["bundled.product"])
        XCTAssertEqual(bundled.parameters, values)
        do {
            _ = try await repository.fallback(for: bundled, failure: URLError(.cannotConnectToHost))
            XCTFail("A bundle failure must end at Retry/Close")
        } catch { }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "Live fallback must not refetch the manifest")
    }

    func testWithoutBundleLastOriginFailureSurfacesError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: primary,
            cacheDirectory: directory, fallbackOrigins: [backups[0]]),
            transport: StubTransport([.response(try manifestResponse([placement(Data("x".utf8))]))]))
        let live = try await repository.resolve("paywall")
        let backup = try await repository.fallback(for: live, failure: URLError(.cannotConnectToHost))
        XCTAssertEqual(backup.indexURL.host, "api.flowdeck.example")
        do {
            _ = try await repository.fallback(for: backup, failure: URLError(.timedOut))
            XCTFail("Without a bundle the native Retry/Close error remains")
        } catch { XCTAssertEqual((error as NSError).code, URLError.timedOut.rawValue) }
    }

    func testManifestFallbackOriginServesLivePageFromSameOrigin() async throws {
        for failure in [StubTransport.Result.offline, .response(.init(data: Data(), status: 503, etag: nil))] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let transport = StubTransport([failure, .response(try manifestResponse([placement(Data("x".utf8))]))])
            let repository = try ContentRepository(configuration: .init(apiKey: "secret", baseURL: primary,
                cacheDirectory: directory, fallbackOrigins: backups), transport: transport)
            let live = try await repository.resolve("paywall")
            XCTAssertEqual(live.indexURL.absoluteString, "https://api.flowdeck.example/live/test/paywall/")
            XCTAssertEqual(live.liveAlternates.map(\.absoluteString), ["https://backup.flowdeck.example/live/test/paywall/"],
                           "The failed primary is not retried for this presentation")
            let requests = await transport.requests
            XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
                "https://flowdeck.proxy.example/v1/sdk/placements",
                "https://api.flowdeck.example/v1/sdk/placements"
            ])
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret" })
        }
    }

    func testAllManifestOriginsFailingUsesBundleOrThrows() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = StubTransport([.offline, .offline, .offline])
        let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: primary,
            cacheDirectory: directory, fallbackOrigins: backups), transport: transport)
        do {
            _ = try await repository.resolve("paywall")
            XCTFail("No origin and no bundle must surface an error")
        } catch { }
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testWithoutFallbackOriginsBehaviorIsUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try zip()
        let bundle = directory.appendingPathComponent("paywall.zip")
        try bytes.write(to: bundle)
        let transport = StubTransport([.response(try manifestResponse([placement(Data("x".utf8))])), .offline])
        let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: primary,
            fallbackPackages: [.init(placementID: "paywall", kind: .paywall, zipURL: bundle, sha256: PackageCache.hash(bytes))],
            cacheDirectory: directory), transport: transport)
        let live = try await repository.resolve("paywall")
        XCTAssertTrue(live.liveAlternates.isEmpty)
        let fallback = try await repository.fallback(for: live, failure: FlowdeckError.httpStatus(404))
        XCTAssertEqual(fallback.source, .bundled)
        let offline = try await repository.resolve("paywall")
        XCTAssertEqual(offline.source, .bundled)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "flowdeck.proxy.example" })
    }

    func testInvalidOrDuplicateFallbackOriginsAreRejected() throws {
        for value in [
            "http://api.flowdeck.example", "https://api.flowdeck.example/v1", "https://api.flowdeck.example?x=1",
            "https://api.flowdeck.example#x", "https://user@api.flowdeck.example", "file:///tmp/live",
            "https://FLOWDECK.proxy.example", "https://flowdeck.proxy.example:443", "*"
        ] {
            let origin = try XCTUnwrap(URL(string: value), value)
            XCTAssertThrowsError(try FlowdeckConfiguration(apiKey: "key", baseURL: primary,
                fallbackOrigins: [origin]).validate(), value)
        }
        XCTAssertThrowsError(try FlowdeckConfiguration(apiKey: "key", baseURL: primary,
            fallbackOrigins: [backups[0], URL(string: "https://API.flowdeck.example/")!]).validate())
        XCTAssertNoThrow(try FlowdeckConfiguration(apiKey: "key", baseURL: primary, fallbackOrigins: backups).validate())
        XCTAssertNoThrow(try FlowdeckConfiguration(apiKey: "key", baseURL: URL(string: "http://127.0.0.1:8081")!,
            fallbackOrigins: [URL(string: "http://127.0.0.1:8082")!]).validate())
    }

    func testTrustFollowsOnlyTheLoadedOrigin() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try ContentRepository(configuration: .init(apiKey: "key", baseURL: primary,
            cacheDirectory: directory, fallbackOrigins: backups),
            transport: StubTransport([.response(try manifestResponse([placement(Data("x".utf8))]))]))
        let live = try await repository.resolve("paywall")
        let backup = try await repository.fallback(for: live, failure: URLError(.timedOut))
        // Before fallback only the primary page is trusted; a redirect to the backup origin is blocked.
        XCTAssertTrue(LivePage.allows(live.indexURL, trusted: live.indexURL))
        XCTAssertFalse(LivePage.allows(backup.indexURL, trusted: live.indexURL))
        // After fallback the failed primary is no longer trusted.
        XCTAssertTrue(LivePage.allows(backup.indexURL, trusted: backup.indexURL))
        XCTAssertFalse(LivePage.allows(live.indexURL, trusted: backup.indexURL))
        for value in ["https://evil.example/live/test/paywall/", "https://backup.flowdeck.example/live/test/paywall/",
                      "https://api.flowdeck.example/live/test/other/"] {
            XCTAssertFalse(LivePage.allows(URL(string: value), trusted: backup.indexURL), value)
        }
        let trusted = backup.indexURL
        let bridge = try await MainActor.run { try BridgeScript.userScript(parameters: .init(), trustedURL: trusted).source }
        XCTAssertEqual(bridgeType(bridge, host: "api.flowdeck.example", path: "/live/test/paywall/"), "object")
        XCTAssertEqual(bridgeType(bridge, host: "flowdeck.proxy.example", path: "/live/test/paywall/"), "undefined")
        XCTAssertEqual(bridgeType(bridge, host: "backup.flowdeck.example", path: "/live/test/paywall/"), "undefined")
        XCTAssertEqual(bridgeType(bridge, host: "api.flowdeck.example", path: "/live/test/paywall/", main: false), "undefined")
        XCTAssertFalse(bridge.contains("secret") || bridge.contains("Bearer"), "The API key never enters the WebView")
    }

    /// Evaluates the bridge with a real `URL` implementation from JavaScriptCore's host-free context.
    private func bridgeType(_ script: String, host: String, path: String, main: Bool = true) -> String? {
        let context = JSContext()!
        context.evaluateScript("""
            var window = this; window.top = \(main ? "window" : "{}");
            var document = { addEventListener() {} };
            var location = {protocol:'https:',host:'\(host)',pathname:'\(path)'};
            """)
        if context.evaluateScript("typeof URL")?.toString() != "function" {
            context.evaluateScript("""
                function URL(value) { const m = /^(\\w+:)\\/\\/([^/]+)(\\/.*)$/.exec(value);
                  this.protocol = m[1]; this.host = m[2]; this.pathname = m[3]; }
                """)
        }
        context.evaluateScript(script)
        XCTAssertNil(context.exception)
        return context.evaluateScript("typeof window.flowdeck")?.toString()
    }
}
