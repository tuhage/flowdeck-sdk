import Foundation
import WebKit

@MainActor
enum BridgeScript {
    static func userScript(parameters: PlacementParameters, trustedURL: URL? = nil) throws -> WKUserScript {
        guard let url = Bundle.module.url(forResource: "bridge", withExtension: "js") else {
            throw FlowdeckError.invalidConfiguration
        }
        let bridge = try String(contentsOf: url, encoding: .utf8)
        let json = String(decoding: try JSONEncoder().encode(parameters), as: UTF8.self)
        // Parse a JSON string rather than an object literal, preserving keys such as __proto__.
        let literal = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let guardScript: String
        if let trustedURL {
            let address = String(decoding: try JSONEncoder().encode(trustedURL.absoluteString), as: UTF8.self)
            guardScript = """
            const trusted = new URL(\(address));
            if (window !== window.top || location.protocol !== trusted.protocol ||
                location.host !== trusted.host || location.pathname !== trusted.pathname) return;
            """
        } else {
            guardScript = ""
        }
        return WKUserScript(source: "(parameters => {\n\(guardScript)\n\(bridge)\n})(JSON.parse(\(literal)));",
                            injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }
}
