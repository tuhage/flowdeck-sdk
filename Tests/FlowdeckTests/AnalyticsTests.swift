import Foundation
import Testing
import JavaScriptCore
@testable import Flowdeck

private actor EventTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var fail = false
    func setFailure(_ value: Bool) { fail = value }
    func get(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if fail { throw URLError(.notConnectedToInternet) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [[String: Any]]]
        return HTTPResponse(data: Data("{\"accepted\":\(body["events"]!.count)}".utf8), status: 200, etag: nil)
    }
}

@Suite struct AnalyticsTests {
    private func configuration() -> FlowdeckConfiguration {
        FlowdeckConfiguration(apiKey: "test", baseURL: URL(string: "https://example.com")!,
            cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    private func event(_ page: String = "welcome", date: Date = Date()) -> PlacementEvent {
        .init(placement_id: "onboarding", page: page, type: "impression", target: "", occurred_at: date)
    }

    @Test func batchingAndWireContract() async throws {
        let config = configuration()
        defer { try? FileManager.default.removeItem(at: config.cacheDirectory) }
        let transport = EventTransport()
        let queue = EventQueue(configuration: config, transport: transport)
        for _ in 0..<105 { await queue.enqueue(event()) }
        await queue.flush()
        await queue.flush()
        await queue.flush()
        let requests = await transport.requests
        #expect(requests.count == 2)
        for (request, count) in zip(requests, [100, 5]) {
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/sdk/events")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
            #expect(request.httpBody!.count < 65536)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [[String: String]]]
            #expect(body["events"]?.count == count)
            #expect(Set(body["events"]![0].keys) == ["placement_id", "page", "type", "target", "occurred_at"])
            #expect(ISO8601DateFormatter().date(from: body["events"]![0]["occurred_at"]!) != nil)
        }
    }

    @Test func offlineRetentionCapacityAndRelaunch() async throws {
        let config = configuration()
        defer { try? FileManager.default.removeItem(at: config.cacheDirectory) }
        let transport = EventTransport()
        await transport.setFailure(true)
        let queue = EventQueue(configuration: config, transport: transport, capacity: 2)
        await queue.enqueue(event("one"))
        await queue.enqueue(event("two"))
        await queue.enqueue(event("overflow"))
        let now = Date()
        await queue.flush(now: now)
        await queue.flush(now: now.addingTimeInterval(5))
        #expect(await transport.requests.count == 1)
        await transport.setFailure(false)
        await queue.flush(now: now.addingTimeInterval(31))
        #expect(await transport.requests.count == 2)
        await queue.enqueue(event("persisted"))
        let restored = EventQueue(configuration: config, transport: transport)
        await restored.flush()
        let request = await transport.requests.last!
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [[String: String]]]
        #expect(body["events"]?.map { $0["page"]! } == ["persisted"])
    }

    @Test func expiredEventsDoNotBlockBatch() async {
        let config = configuration()
        defer { try? FileManager.default.removeItem(at: config.cacheDirectory) }
        let transport = EventTransport()
        let queue = EventQueue(configuration: config, transport: transport)
        await queue.enqueue(event(date: Date().addingTimeInterval(-30 * 86400)))
        await queue.flush()
        #expect(await transport.requests.isEmpty)
    }

    @MainActor @Test func automaticLifecycleAndPageAttribution() async throws {
        var events: [PlacementEvent] = []
        let tracker = PresentationAnalytics(placementID: "onboarding") { events.append($0) }
        let content = FlowdeckContent(placementID: "onboarding", kind: .onboarding, productIDs: [],
            indexURL: URL(fileURLWithPath: "/package/index.html"), source: .cache, fallbackReason: nil)
        let router = BridgeRouter(content: content, commerce: FakeCommerce(), emit: { _ in },
                                  review: {}, openURL: { _ in false }, analytics: tracker)
        tracker.appear()
        tracker.appear()
        for json in [
            #"{"id":"1","method":"page","params":{"name":"welcome"}}"#,
            #"{"id":"2","method":"page","params":{"name":"ad"}}"#,
            #"{"id":"3","method":"click","params":{"target":"app_store"}}"#
        ] { _ = await router.handle(try BridgeMessage.parse(Data(json.utf8))) }
        tracker.close()
        tracker.close()
        tracker.click("ignored")
        #expect(events.map(\.type) == ["impression", "impression", "impression", "click", "close"])
        #expect(events.map(\.page) == ["", "welcome", "ad", "ad", "ad"])
        #expect(events[3].target == "app_store")
    }

    @MainActor @Test func scriptReportsPageAndDelegatesNestedClicks() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
            var window = this; window.top = window;
            var messages = [];
            var document = { addEventListener(type, handler, capture) {
                window.clickHandler = handler; window.capture = capture;
            }};
            class Element {
                closest(selector) { return this.match; }
                getAttribute(name) { return 'ad'; }
            }
            window.webkit = { messageHandlers: { flowdeck: { postMessage(message) {
                messages.push(message); return Promise.resolve({result: null});
            }}}};
            window.dispatchEvent = () => {};
            window.CustomEvent = class {};
            """)
        context.evaluateScript(try BridgeScript.userScript(parameters: PlacementParameters()).source)
        context.evaluateScript("""
            window.flowdeck.page('welcome');
            window.flowdeck.click('explicit');
            var parent = new Element(); var child = new Element(); child.match = parent;
            clickHandler({target: child});
            clickHandler({target: new Element()});
            clickHandler({target: {}});
            """)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("capture")?.toBool() == true)
        #expect(context.evaluateScript("JSON.stringify(messages.map(m => [m.method, m.params]))")?.toString()
            == #"[["page",{"name":"welcome"}],["click",{"target":"explicit"}],["click",{"target":"ad"}]]"#)
    }

    @Test func bridgeRejectsInvalidAnalyticsNames() throws {
        for name in ["https://example.com", "user name", "é", String(repeating: "a", count: 65)] {
            for (method, key) in [("page", "name"), ("click", "target")] {
                let data = try JSONSerialization.data(withJSONObject: ["id": "1", "method": method, "params": [key: name]])
                #expect(throws: FlowdeckError.self) { try BridgeMessage.parse(data) }
            }
        }
    }
}
