import Foundation
import Testing
@testable import Flowdeck

@Test(arguments: [
    #"{"id":"1","method":"purchase","params":{"productId":"pro.weekly"}}"#,
    #"{"id":"2","method":"event","params":{"name":"viewed","props":{"step":2,"ok":true,"text":"a'\\b","nested":[null]}}}"#,
    #"{"id":"3","method":"openURL","params":{"url":"https://example.com/privacy"}}"#
])
func validBridgeMessages(json: String) throws { _ = try BridgeMessage.parse(Data(json.utf8)) }

@Test(arguments: [
    #"{"id":"","method":"close","params":{}}"#,
    #"{"id":"1","method":"unknown","params":{}}"#,
    #"{"id":"1","method":"purchase","params":{}}"#,
    #"{"id":"1","method":"purchase","params":{"productId":3}}"#,
    #"{"id":"1","method":"close","params":{"unexpected":true}}"#,
    #"{"id":"1","method":"openURL","params":{"url":"javascript:alert(1)"}}"#,
    #"{"id":"1","method":"openURL","params":{"url":"file:///private/key"}}"#,
    #"{"id":"1","method":"openURL","params":{"url":"https://user:password@example.com"}}"#,
    #"{"id":"1","method":"event","params":{"name":"viewed","props":[]}}"#,
    #"{"id":"1","method":"event","params":{"name":"","props":{}}}"#,
    #"{"id":"1","method":"restore"}"#,
    "[]"
])
func invalidBridgeMessages(json: String) {
    #expect(throws: FlowdeckError.self) { try BridgeMessage.parse(Data(json.utf8)) }
}

@Test func oversizedMessagesRejected() {
    #expect(throws: FlowdeckError.self) { try BridgeMessage.parse(Data(repeating: 32, count: 65_537)) }
}

@MainActor
final class FakeCommerce: Commerce {
    var purchased: [String] = []
    var restored = false
    func products(ids: [String]) async throws -> [FlowdeckProduct] { [] }
    func purchase(productID: String) async throws -> FlowdeckPurchaseResult {
        purchased.append(productID)
        return .init(status: .cancelled, transaction: nil, entitlements: [])
    }
    func restore() async throws -> [FlowdeckEntitlement] { restored = true; return [] }
    func entitlements() async -> [FlowdeckEntitlement] { [] }
}

@MainActor @Test func bridgeRoutesResultsAndEnforcesProductAndOnboardingScope() async throws {
    let commerce = FakeCommerce()
    var events: [FlowdeckEvent] = []
    var reviews = 0
    var urls: [URL] = []
    let content = FlowdeckContent(placementID: "paywall", kind: .paywall, productIDs: ["pro.weekly"],
                                 indexURL: URL(fileURLWithPath: "/package/index.html"), source: .cache, fallbackReason: nil)
    let router = BridgeRouter(content: content, commerce: commerce, emit: { events.append($0) },
                              review: { reviews += 1 }, openURL: { urls.append($0); return true })
    func send(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> FlowdeckBridgeResponse {
        let data = try JSONEncoder().encode(JSONValue.object(["id": .string("123"), "method": .string(method), "params": .object(params)]))
        return await router.handle(try BridgeMessage.parse(data))
    }
    #expect(try await send("purchase", ["productId": .string("unlisted")]).error != nil)
    #expect(commerce.purchased.isEmpty)
    let result = try await send("purchase", ["productId": .string("pro.weekly")])
    #expect(result.error == nil)
    #expect(result.id == "123")
    #expect(commerce.purchased == ["pro.weekly"])
    #expect(try await send("restore").error == nil)
    #expect(commerce.restored)
    #expect(try await send("requestReview").error == nil)
    #expect(reviews == 1)
    #expect(try await send("openURL", ["url": .string("https://example.com")]).error == nil)
    #expect(urls.count == 1)
    #expect(try await send("event", ["name": .string("clicked"), "props": .object(["x": .number(1)])]).error == nil)
    #expect(try await send("completeOnboarding").error != nil)
    #expect(!events.contains { if case .onboardingCompleted = $0 { return true }; return false })
    let onboarding = BridgeRouter(content: .init(placementID: "onboarding", kind: .onboarding, productIDs: [],
        indexURL: content.indexURL, source: .bundled, fallbackReason: nil), commerce: commerce,
        emit: { events.append($0) }, review: {}, openURL: { _ in false })
    _ = await onboarding.handle(BridgeMessage(id: "4", method: .completeOnboarding, params: [:]))
    #expect(events.contains { if case .onboardingCompleted = $0 { return true }; return false })
    #expect(events.contains { if case .bridge(_, let response) = $0 { return response == result }; return false })
}
