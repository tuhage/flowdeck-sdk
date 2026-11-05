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
        context.evaluateScript("var window = this; window.top = window; var document = { addEventListener() {} };")
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
