#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import Flowdeck

final class LiveFallbackWebViewTests: XCTestCase {
    @MainActor
    func testUnreachableLivePageLoadsBundleWithNativeBridge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try zip()
        let bundle = directory.appendingPathComponent("fallback.zip")
        try bytes.write(to: bundle)
        let loaded = expectation(description: "Bundle loaded after live connection failure")
        let sdk = try Flowdeck(configuration: .init(apiKey: "test", baseURL: URL(string: "http://127.0.0.1:9")!,
            fallbackPackages: [.init(placementID: "onboarding", kind: .onboarding, zipURL: bundle, sha256: PackageCache.hash(bytes))],
            cacheDirectory: directory)) { event in
                if case .loaded(let content) = event, content.source == .bundled { loaded.fulfill() }
            }
        let controller = FlowdeckViewController(flowdeck: sdk, content: liveContent())
        controller.loadViewIfNeeded()
        await fulfillment(of: [loaded], timeout: 15)
        XCTAssertEqual(controller.content.source, .bundled)
        let web = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        let values = try await web.callAsyncJavaScript("return await window.flowdeck.getParameters();",
            arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(values?["ask_review"] as? Bool, false)
        let closed = expectation(description: "Bundled bridge close")
        controller.onDismiss = { closed.fulfill() }
        _ = try await web.callAsyncJavaScript("await window.flowdeck.close(); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [closed], timeout: 5)
    }

    @MainActor
    func testNoBundleShowsRetryAndCloseAndRetryAttemptsLiveAgain() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = expectation(description: "Live load failed")
        let retried = expectation(description: "Retry attempted live load")
        var failures = 0
        let sdk = try Flowdeck(configuration: .init(apiKey: "test", baseURL: URL(string: "http://127.0.0.1:9")!,
            cacheDirectory: directory)) { event in
                if case .failed = event {
                    failures += 1
                    if failures == 1 { failed.fulfill() }
                    if failures == 2 { retried.fulfill() }
                }
            }
        let controller = FlowdeckViewController(flowdeck: sdk, content: liveContent())
        controller.loadViewIfNeeded()
        await fulfillment(of: [failed], timeout: 15)
        let web = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        controller.webView(web, didFailProvisionalNavigation: nil, withError: URLError(.cannotConnectToHost))
        XCTAssertEqual(failures, 1, "Late duplicate failure must not replace the original error")
        let stack = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UIStackView }.first)
        XCTAssertFalse(stack.isHidden)
        let buttons = stack.arrangedSubviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.map { $0.title(for: .normal) }, ["Retry", "Close"])
        buttons[0].sendActions(for: .touchUpInside)
        await fulfillment(of: [retried], timeout: 15)
        XCTAssertFalse(stack.isHidden)
        XCTAssertEqual(controller.content.source, .network)
        var closed = false
        controller.onDismiss = { closed = true }
        buttons[1].sendActions(for: .touchUpInside)
        XCTAssertTrue(closed)
    }

    private func liveContent() -> FlowdeckContent {
        FlowdeckContent(placementID: "onboarding", kind: .onboarding, productIDs: [],
            indexURL: URL(string: "http://127.0.0.1:9/live/test/onboarding/")!,
            source: .network, fallbackReason: nil,
            parameters: try! parameters(#"{"ask_review":false}"#))
    }
}
#endif
