import Foundation
import XCTest
import JavaScriptCore
@testable import Flowdeck

final class LivePageTests: XCTestCase {
    @MainActor
    func testBridgeScriptIsAbsentOutsideTrustedMainDocument() throws {
        let trusted = URL(string: "https://example.com/live/test/paywall/")!
        let script = try BridgeScript.userScript(parameters: .init(), trustedURL: trusted)
        for (host, path, main, expected) in [
            ("example.com", "/live/test/paywall/", true, "object"),
            ("evil.example", "/live/test/paywall/", true, "undefined"),
            ("example.com", "/live/test/other/", true, "undefined"),
            ("example.com", "/live/test/paywall/", false, "undefined")
        ] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("""
                var window = this; window.top = \(main ? "window" : "{}");
                var document = { addEventListener() {} };
                var location = {protocol:'https:',host:'\(host)',pathname:'\(path)'};
                function URL() { this.protocol='https:'; this.host='example.com'; this.pathname='/live/test/paywall/'; }
                """)
            context.evaluateScript(script.source)
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("typeof window.flowdeck")?.toString(), expected)
        }
    }

    func testURLAndTrustBoundary() throws {
        let url = try LivePage.url(baseURL: URL(string: "https://custom.example")!, appID: "my-app", placementID: "onboarding_ru")
        XCTAssertEqual(url.absoluteString, "https://custom.example/live/my-app/onboarding_ru/")
        XCTAssertTrue(LivePage.allows(url, trusted: url))
        XCTAssertTrue(LivePage.allows(URL(string: url.absoluteString + "#step2"), trusted: url))
        for value in [
            "http://custom.example/live/my-app/onboarding_ru/",
            "https://custom.example:444/live/my-app/onboarding_ru/",
            "https://evil.example/live/my-app/onboarding_ru/",
            "https://custom.example/live/my-app/onboarding_ru-other/",
            "https://custom.example/live/my-app/other/",
            "https://custom.example/live/my-app/onboarding_ru/../other/",
            "https://custom.example/live/my-app/onboarding_ru/%2e%2e/other/",
            "https://user@custom.example/live/my-app/onboarding_ru/",
            "https://custom.example/live/my-app/onboarding_ru/frame.html"
        ] { XCTAssertFalse(LivePage.allows(URL(string: value), trusted: url), value) }
        XCTAssertThrowsError(try LivePage.url(baseURL: url, appID: "../escape", placementID: "paywall"))
    }

    func testResolveOnlyFetchesManifestAndRefreshesParameters() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("metadata".utf8)
        let changed = try parameters(#"{"ask_review":false}"#)
        let transport = StubTransport([
            .response(try manifestResponse([placement(bytes)])),
            .response(try manifestResponse([placement(bytes, parameters: changed)]))
        ])
        let repository = try ContentRepository(configuration: .init(apiKey: "secret",
            baseURL: URL(string: "https://custom.example")!, cacheDirectory: directory), transport: transport)
        let first = try await repository.resolve("paywall")
        let second = try await repository.resolve("paywall")
        XCTAssertEqual(first.indexURL.absoluteString, "https://custom.example/live/test/paywall/")
        XCTAssertEqual(second.parameters, changed)
        XCTAssertEqual(second.source, .network)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/v1/sdk/placements" })
        let files = FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String] ?? []
        XCTAssertFalse(files.contains { $0.hasSuffix(".zip") || $0.hasSuffix("index.html") })
    }

    func testETagAndRemovalRemainAuthoritativeForLegacyBundle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try zip()
        let bundle = directory.appendingPathComponent("bundle.zip")
        try bytes.write(to: bundle)
        let values = try parameters(#"{"ask_review":false}"#)
        let transport = StubTransport([
            .response(try manifestResponse([placement(bytes, parameters: values)])),
            .response(.init(data: Data(), status: 304, etag: nil)),
            .offline,
            .response(try manifestResponse([])),
            .offline
        ])
        let repository = try ContentRepository(configuration: .init(apiKey: "key",
            baseURL: URL(string: "https://example.com")!,
            fallbackPackages: [.init(placementID: "paywall", kind: .paywall, zipURL: bundle, sha256: PackageCache.hash(bytes))],
            cacheDirectory: directory), transport: transport)
        _ = try await repository.resolve("paywall")
        let revalidated = try await repository.resolve("paywall")
        XCTAssertEqual(revalidated.source, .network)
        let requests = await transport.requests
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        let fallback = try await repository.resolve("paywall")
        XCTAssertEqual(fallback.source, .bundled)
        XCTAssertEqual(fallback.parameters, values)
        for _ in 0..<2 {
            do {
                _ = try await repository.resolve("paywall")
                XCTFail("Removed placements must not revive a bundled page")
            } catch FlowdeckError.placementNotFound { }
        }
    }

    func testOfflineAndHTTPFailuresDoNotReviveCachedPages() async throws {
        for result in [StubTransport.Result.offline, .response(.init(data: Data(), status: 503, etag: nil))] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let transport = StubTransport([.response(try manifestResponse([placement(Data("metadata".utf8))])), result])
            let repository = try ContentRepository(configuration: .init(apiKey: "key",
                baseURL: URL(string: "https://example.com")!, cacheDirectory: directory), transport: transport)
            _ = try await repository.resolve("paywall")
            do {
                _ = try await repository.resolve("paywall")
                XCTFail("A failed refresh must surface to the host retry UI")
            } catch { }
        }
    }
}
