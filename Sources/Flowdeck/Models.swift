import Foundation

public enum FlowdeckError: Error, LocalizedError, Sendable {
    case invalidConfiguration, invalidManifest, invalidPackage, hashMismatch
    case httpStatus(Int), invalidResponse, placementNotFound(String)
    case invalidMessage, productNotAllowed, productUnavailable, unverifiedTransaction
    case purchaseInProgress, unavailableScene, navigationBlocked

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid Flowdeck configuration."
        case .invalidManifest: "Invalid placement manifest."
        case .invalidPackage: "Invalid or unsafe HTML package."
        case .hashMismatch: "Package SHA-256 does not match."
        case .httpStatus(let status): "Flowdeck HTTP status \(status)."
        case .invalidResponse: "Invalid Flowdeck response."
        case .placementNotFound(let id): "No usable package for placement \(id)."
        case .invalidMessage: "Invalid bridge message."
        case .productNotAllowed: "Product is not listed in this placement."
        case .productUnavailable: "Product is unavailable in this storefront."
        case .unverifiedTransaction: "StoreKit transaction could not be verified."
        case .purchaseInProgress: "A purchase or restore is already in progress."
        case .unavailableScene: "No active window scene is available."
        case .navigationBlocked: "Navigation outside the local package is blocked."
        }
    }
}

public struct Placement: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case paywall, onboarding }
    public let id: String
    public let kind: Kind
    public let version: Int
    public let hash: String
    public let size: Int
    public let url: String
    public let productIDs: [String]
    public let publishedAt: String
    public let parameters: PlacementParameters

    enum CodingKeys: String, CodingKey {
        case id, kind, version, hash, size, url, parameters
        case productIDs = "product_ids", publishedAt = "published_at"
    }

    init(id: String, kind: Kind, version: Int, hash: String, size: Int, url: String,
         productIDs: [String], publishedAt: String, parameters: PlacementParameters = .init()) {
        self.id = id
        self.kind = kind
        self.version = version
        self.hash = hash
        self.size = size
        self.url = url
        self.productIDs = productIDs
        self.publishedAt = publishedAt
        self.parameters = parameters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id),
                  kind: try container.decode(Kind.self, forKey: .kind),
                  version: try container.decode(Int.self, forKey: .version),
                  hash: try container.decode(String.self, forKey: .hash),
                  size: try container.decode(Int.self, forKey: .size),
                  url: try container.decode(String.self, forKey: .url),
                  productIDs: try container.decode([String].self, forKey: .productIDs),
                  publishedAt: try container.decode(String.self, forKey: .publishedAt),
                  parameters: container.contains(.parameters)
                    ? try container.decode(PlacementParameters.self, forKey: .parameters) : .init())
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9_-]{0,62}$", options: .regularExpression) != nil
    }
    static func validHash(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
    static func validProducts(_ values: [String]) -> Bool {
        values.count <= 20 && Set(values).count == values.count && values.allSatisfy {
            $0.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil
        }
    }
    func validate() throws {
        guard Self.validID(id), Self.validHash(hash), version > 0,
              size > 0, size <= PackageCache.maxZIPSize,
              url == "/v1/sdk/packages/\(hash)", Self.validProducts(productIDs) else {
            throw FlowdeckError.invalidManifest
        }
    }
}

struct Manifest: Codable, Sendable {
    let appID: String
    let placements: [Placement]
    enum CodingKeys: String, CodingKey { case appID = "app_id", placements }
    func validate() throws {
        guard !appID.isEmpty, Set(placements.map(\.id)).count == placements.count else {
            throw FlowdeckError.invalidManifest
        }
        try placements.forEach { try $0.validate() }
    }
}

public struct FlowdeckContent: Sendable {
    public enum Source: String, Sendable { case network, cache, bundled }
    public let placementID: String
    public let kind: Placement.Kind
    public let productIDs: [String]
    public let indexURL: URL
    public let source: Source
    /// Why an older cached or bundled package was selected, if applicable.
    public let fallbackReason: String?
    public let parameters: PlacementParameters

    init(placementID: String, kind: Placement.Kind, productIDs: [String], indexURL: URL,
         source: Source, fallbackReason: String?, parameters: PlacementParameters = .init()) {
        self.placementID = placementID
        self.kind = kind
        self.productIDs = productIDs
        self.indexURL = indexURL
        self.source = source
        self.fallbackReason = fallbackReason
        self.parameters = parameters
    }
}
