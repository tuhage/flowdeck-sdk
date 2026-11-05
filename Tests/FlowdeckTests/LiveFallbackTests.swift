import Foundation
import XCTest
@testable import Flowdeck

final class LiveFallbackTests: XCTestCase {
    func testLiveFailuresSelectOnlyConfiguredBundleAndKeepPresentationParameters() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try zip([("index.html", "<h1>Offline onboarding</h1>")])
        let bundle = directory.appendingPathComponent("onboarding.zip")
        try bytes.write(to: bundle)
        let transport = StubTransport([])
        let repository = try ContentRepository(configuration: .init(apiKey: "key",
            baseURL: URL(string: "https://example.com")!,
            fallbackPackages: [.init(placementID: "onboarding", kind: .onboarding, zipURL: bundle,
                                      sha256: PackageCache.hash(bytes), productIDs: ["bundled.product"])],
            cacheDirectory: directory), transport: transport)
        let values = try parameters(#"{"ask_review":false}"#)
        let live = FlowdeckContent(placementID: "onboarding", kind: .onboarding, productIDs: ["live.product"],
            indexURL: URL(string: "https://example.com/live/test/onboarding/")!,
            source: .network, fallbackReason: nil, parameters: values)
        let failures: [any Error] = [
            URLError(.notConnectedToInternet), URLError(.cannotConnectToHost),
            URLError(.timedOut), FlowdeckError.httpStatus(404), FlowdeckError.httpStatus(503)
        ]
        for failure in failures {
            let fallback = try await repository.fallback(for: live, failure: failure)
            XCTAssertEqual(fallback.source, .bundled)
            XCTAssertTrue(fallback.indexURL.isFileURL)
            XCTAssertEqual(try String(contentsOf: fallback.indexURL, encoding: .utf8), "<h1>Offline onboarding</h1>")
            XCTAssertEqual(fallback.parameters, values)
            XCTAssertEqual(fallback.kind, .onboarding)
            XCTAssertEqual(fallback.productIDs, ["bundled.product"])
            XCTAssertEqual(fallback.fallbackReason, failure.localizedDescription)
            do {
                _ = try await repository.fallback(for: fallback, failure: failure)
                XCTFail("A bundle failure must not loop into another fallback")
            } catch { }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "Fallback must not attempt another network fetch")
    }

    func testMissingAndInvalidBundlesSurfaceErrorsForRetryClose() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("broken.zip")
        try Data("corrupt".utf8).write(to: bundle)
        let live = FlowdeckContent(placementID: "onboarding", kind: .onboarding, productIDs: [],
            indexURL: URL(string: "https://example.com/live/test/onboarding/")!, source: .network, fallbackReason: nil)
        for fallbacks: [FlowdeckFallbackPackage] in [
            [],
            [.init(placementID: "another", kind: .onboarding, zipURL: bundle, sha256: String(repeating: "a", count: 64))],
            [.init(placementID: "onboarding", kind: .onboarding, zipURL: bundle, sha256: String(repeating: "a", count: 64))]
        ] {
            let repository = try ContentRepository(configuration: .init(apiKey: "key",
                baseURL: URL(string: "https://example.com")!, fallbackPackages: fallbacks,
                cacheDirectory: directory), transport: StubTransport([]))
            do {
                _ = try await repository.fallback(for: live, failure: URLError(.timedOut))
                XCTFail("An absent or invalid bundle must preserve the native error path")
            } catch {
                if fallbacks.first?.placementID != "onboarding" {
                    XCTAssertEqual((error as NSError).code, URLError.timedOut.rawValue)
                }
            }
        }
    }
}
