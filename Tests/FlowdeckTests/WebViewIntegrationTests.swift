#if os(iOS)
import SwiftUI
import WebKit
import XCTest
@testable import Flowdeck

final class WebViewIntegrationTests: XCTestCase {
    @MainActor
    func testLocalHTMLBridgeRoundTripNavigationAndDismissal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try zip([("index.html", """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Flowdeck bridge test</title><h1>Local HTML</h1>
            <script>
              window.bridgeAtStart = typeof window.flowdeck;
              window.parametersAtStart = window.flowdeck.parameters;
            </script>
            """)])
        let index = try PackageCache(root: directory).store(bytes, hash: PackageCache.hash(bytes))
        var events: [FlowdeckEvent] = []
        let loaded = expectation(description: "Local package loaded")
        let sdk = try Flowdeck(configuration: .init(apiKey: "test", baseURL: URL(string: "http://127.0.0.1:9")!,
                                                    cacheDirectory: directory)) { event in
            events.append(event)
            if case .loaded = event { loaded.fulfill() }
        }
        let content = FlowdeckContent(placementID: "onboarding", kind: .onboarding, productIDs: [],
                                      indexURL: index, source: .bundled, fallbackReason: nil,
                                      parameters: try parameters(#"{"ask_review":false,"headline":"Welcome","delay":1.5}"#))
        let controller = FlowdeckViewController(flowdeck: sdk, content: content)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: UIScreen.main.bounds) }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.rootViewController?.present(controller, animated: false)
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [loaded], timeout: 20)
        let web = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        let bridgeAtStart = try await web.evaluateJavaScript("window.bridgeAtStart") as? String
        XCTAssertEqual(bridgeAtStart, "object")
        let parametersAtStart = try await web.evaluateJavaScript("window.parametersAtStart") as? [String: Any]
        XCTAssertEqual(parametersAtStart?["ask_review"] as? Bool, false)
        XCTAssertEqual(parametersAtStart?["headline"] as? String, "Welcome")
        XCTAssertEqual(parametersAtStart?["delay"] as? Double, 1.5)
        let result = try await web.callAsyncJavaScript("""
            const responses = [];
            window.addEventListener('flowdeck:result', e => responses.push(e.detail.method));
            const parameters = await window.flowdeck.getParameters();
            const parametersMatch = JSON.stringify(parameters, Object.keys(parameters).sort()) ===
              JSON.stringify(window.parametersAtStart, Object.keys(window.parametersAtStart).sort());
            await window.flowdeck.event('button_clicked', {step: 2, quote: "it's working"});
            let blocked = false;
            try { await window.flowdeck.purchase('not.listed'); } catch (e) { blocked = e.code === 'native_error'; }
            await window.flowdeck.completeOnboarding();
            return {blocked, responses, parametersMatch, hasBridge: typeof window.flowdeck.close === 'function'};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["blocked"] as? Bool, true)
        XCTAssertEqual(result?["hasBridge"] as? Bool, true)
        XCTAssertEqual(result?["parametersMatch"] as? Bool, true)
        XCTAssertEqual(result?["responses"] as? [String], ["getParameters", "event", "purchase", "completeOnboarding"])
        XCTAssertTrue(events.contains { if case .event(_, "button_clicked", let props) = $0 { return props["step"] == .number(2) }; return false })
        XCTAssertEqual(events.filter { if case .onboardingCompleted = $0 { return true }; return false }.count, 1)
        let iframeResult = try await web.callAsyncJavaScript("""
            const iframe = document.createElement('iframe');
            const loaded = new Promise(resolve => iframe.onload = resolve);
            iframe.src = window.location.href;
            document.body.appendChild(iframe);
            await loaded;
            try {
              await iframe.contentWindow.webkit.messageHandlers.flowdeck.postMessage({id:'child', method:'close', params:{}});
              return false;
            } catch (_) { return true; }
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(iframeResult, true)
        _ = try await web.evaluateJavaScript("window.addEventListener('flowdeck:entitlements', e => window.lastEntitlements = e.detail)")
        sdk.emit(.entitlementsChanged([]))
        let updated = try await web.callAsyncJavaScript("return window.lastEntitlements;", arguments: [:], in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(updated?.count, 0)
        // Native navigation guard is exercised by an actual link change, with no network request.
        _ = try await web.evaluateJavaScript("window.location.href = 'https://example.com/escape'")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(web.url?.path, index.path)
        XCTAssertTrue(events.contains { if case .failed(_, let message) = $0 { return message == FlowdeckError.navigationBlocked.localizedDescription }; return false })
        let closed = expectation(description: "Native close callback")
        controller.onDismiss = { closed.fulfill() }
        _ = try await web.callAsyncJavaScript("await window.flowdeck.close(); return true;", arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(events.filter { if case .closed = $0 { return true }; return false }.count, 1)
        // Both public presentation surfaces compile and construct under Swift 6.
        _ = UIHostingController(rootView: FlowdeckView(flowdeck: sdk, placementID: "onboarding"))
    }

    @MainActor
    func testSwiftUISheetLoadsFallbackAndClosesFromHTML() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try zip()
        let bundle = directory.appendingPathComponent("embedded.zip")
        try bytes.write(to: bundle)
        let loaded = expectation(description: "SwiftUI sheet loaded offline fallback")
        let closed = expectation(description: "SwiftUI close callback")
        var completed = false
        let sdk = try Flowdeck(configuration: .init(apiKey: "test", baseURL: URL(string: "http://127.0.0.1:9")!,
            fallbackPackages: [.init(placementID: "onboarding", kind: .onboarding, zipURL: bundle,
                                     sha256: PackageCache.hash(bytes))], cacheDirectory: directory)) { event in
            if case .loaded(let content) = event { XCTAssertEqual(content.source, .bundled); loaded.fulfill() }
            if case .onboardingCompleted = event { completed = true }
            if case .closed = event { closed.fulfill() }
        }
        let state = SheetState()
        let hosting = UIHostingController(rootView: TestSheet(state: state, sdk: sdk))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [loaded], timeout: 20)
        func findWebView(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { findWebView($0) }.first
        }
        let presented = try XCTUnwrap(hosting.presentedViewController)
        let web = try XCTUnwrap(findWebView(presented.view))
        _ = try await web.callAsyncJavaScript("await window.flowdeck.completeOnboarding(); await window.flowdeck.close(); return true;",
                                              arguments: [:], in: nil, contentWorld: .page)
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertTrue(completed)
        XCTAssertFalse(state.isPresented)
    }

    @MainActor
    private final class SheetState: ObservableObject {
        @Published var isPresented = true
    }
    @MainActor
    private struct TestSheet: View {
        @ObservedObject var state: SheetState
        let sdk: Flowdeck
        var body: some View {
            Text("Host").sheet(isPresented: $state.isPresented) {
                FlowdeckView(flowdeck: sdk, placementID: "onboarding")
            }
        }
    }

    @MainActor
    func testNavigationCannotEscapeThroughPathPrefixOrSymlink() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("index".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("secret".utf8).write(to: directory.appendingPathComponent("secret"))
        let link = root.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertTrue(FlowdeckViewController.isPackageURL(root.appendingPathComponent("index.html"), root: root))
        XCTAssertFalse(FlowdeckViewController.isPackageURL(directory.appendingPathComponent("package-other/index.html"), root: root))
        XCTAssertFalse(FlowdeckViewController.isPackageURL(link.appendingPathComponent("secret"), root: root))
        XCTAssertFalse(FlowdeckViewController.isPackageURL(URL(string: "https://example.com"), root: root))
    }
}
#endif
