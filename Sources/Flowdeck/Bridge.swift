import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
    static func encoded(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

struct BridgeMessage: Decodable, Sendable {
    enum Method: String, Decodable, Sendable {
        case getParameters, getProducts, purchase, restore, getEntitlements, requestReview, close, openURL, event, completeOnboarding
    }
    let id: String
    let method: Method
    let params: [String: JSONValue]

    static func parse(_ data: Data) throws -> BridgeMessage {
        guard data.count <= 65_536 else { throw FlowdeckError.invalidMessage }
        let value: BridgeMessage
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw FlowdeckError.invalidMessage }
        guard !value.id.isEmpty, value.id.utf8.count <= 128 else { throw FlowdeckError.invalidMessage }
        switch value.method {
        case .purchase:
            guard case .string(let id) = value.params["productId"], Placement.validProducts([id]),
                  value.params.count == 1 else { throw FlowdeckError.invalidMessage }
        case .openURL:
            guard case .string(let url) = value.params["url"], url.count <= 4096,
                  let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme),
                  parsed.host != nil, parsed.user == nil, parsed.password == nil,
                  value.params.count == 1 else { throw FlowdeckError.invalidMessage }
        case .event:
            guard case .string(let name) = value.params["name"], !name.isEmpty, name.utf8.count <= 128,
                  case .object = value.params["props"], value.params.count == 2 else {
                throw FlowdeckError.invalidMessage
            }
        default:
            guard value.params.isEmpty else { throw FlowdeckError.invalidMessage }
        }
        return value
    }
}

public struct FlowdeckBridgeResponse: Codable, Sendable, Equatable {
    public struct Failure: Codable, Sendable, Equatable {
        public let code: String
        public let message: String
    }
    public let id: String
    public let method: String
    public let result: JSONValue?
    public let error: Failure?
}

@MainActor
final class BridgeRouter {
    let content: FlowdeckContent
    let commerce: any Commerce
    let emit: (FlowdeckEvent) -> Void
    let review: () throws -> Void
    let openURL: (URL) async -> Bool

    init(content: FlowdeckContent, commerce: any Commerce, emit: @escaping (FlowdeckEvent) -> Void,
         review: @escaping () throws -> Void, openURL: @escaping (URL) async -> Bool) {
        self.content = content
        self.commerce = commerce
        self.emit = emit
        self.review = review
        self.openURL = openURL
    }

    func handle(_ message: BridgeMessage) async -> FlowdeckBridgeResponse {
        let response: FlowdeckBridgeResponse
        do {
            let result = try await execute(message)
            response = FlowdeckBridgeResponse(id: message.id, method: message.method.rawValue, result: result, error: nil)
        } catch {
            response = FlowdeckBridgeResponse(id: message.id, method: message.method.rawValue, result: nil,
                                             error: .init(code: "native_error", message: error.localizedDescription))
        }
        emit(.bridge(placementID: content.placementID, response: response))
        return response
    }

    private func execute(_ message: BridgeMessage) async throws -> JSONValue {
        switch message.method {
        case .getParameters:
            return try .encoded(content.parameters)
        case .getProducts:
            return try .encoded(await commerce.products(ids: content.productIDs))
        case .purchase:
            guard case .string(let id) = message.params["productId"], content.productIDs.contains(id) else {
                throw FlowdeckError.productNotAllowed
            }
            let result = try await commerce.purchase(productID: id)
            if result.status == .purchased { emit(.entitlementsChanged(result.entitlements)) }
            return try .encoded(result)
        case .restore:
            let entitlements = try await commerce.restore()
            emit(.entitlementsChanged(entitlements))
            return try .encoded(entitlements)
        case .getEntitlements:
            return try .encoded(await commerce.entitlements())
        case .requestReview:
            try review()
            return .object(["requested": .bool(true)])
        case .openURL:
            guard case .string(let value) = message.params["url"], let url = URL(string: value) else {
                throw FlowdeckError.invalidMessage
            }
            return .object(["opened": .bool(await openURL(url))])
        case .event:
            guard case .string(let name) = message.params["name"], case .object(let props) = message.params["props"] else {
                throw FlowdeckError.invalidMessage
            }
            emit(.event(placementID: content.placementID, name: name, props: props))
            return .null
        case .completeOnboarding:
            guard content.kind == .onboarding else { throw FlowdeckError.invalidMessage }
            emit(.onboardingCompleted(placementID: content.placementID))
            return .null
        case .close:
            return .null
        }
    }
}
