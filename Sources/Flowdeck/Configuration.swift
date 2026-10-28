import Foundation

public struct FlowdeckConfiguration: Sendable {
    public let apiKey: String
    /// API origin, e.g. https://flowdeck.example.com (no /v1 suffix).
    public let baseURL: URL
    /// Optional request handlers, scoped to this SDK's session. The default uses ordinary HTTPS.
    public let protocolClasses: [URLProtocol.Type]
    public let fallbackPackages: [FlowdeckFallbackPackage]
    public let cacheDirectory: URL
    /// Optional attribution identity, for example AppMetricKit.appAccountToken.
    public let appAccountToken: UUID?

    public init(apiKey: String, baseURL: URL, protocolClasses: [URLProtocol.Type] = [],
                fallbackPackages: [FlowdeckFallbackPackage] = [],
                cacheDirectory: URL? = nil, appAccountToken: UUID? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.protocolClasses = protocolClasses
        self.fallbackPackages = fallbackPackages
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Flowdeck", isDirectory: true)
        self.appAccountToken = appAccountToken
    }

    func validate() throws {
        let local = ["localhost", "127.0.0.1", "[::1]"].contains(baseURL.host ?? "")
        guard !apiKey.isEmpty, !apiKey.contains("\n"), !apiKey.contains("\r"),
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.scheme == "https" || (local && baseURL.scheme == "http"),
              cacheDirectory.isFileURL,
              Set(fallbackPackages.map(\.placementID)).count == fallbackPackages.count else {
            throw FlowdeckError.invalidConfiguration
        }
        for fallback in fallbackPackages {
            guard fallback.zipURL.isFileURL, Placement.validID(fallback.placementID),
                  Placement.validHash(fallback.sha256), Placement.validProducts(fallback.productIDs) else {
                throw FlowdeckError.invalidConfiguration
            }
        }
    }
}

public struct FlowdeckFallbackPackage: Sendable {
    public let placementID: String
    public let kind: Placement.Kind
    public let zipURL: URL
    public let sha256: String
    public let productIDs: [String]

    public init(placementID: String, kind: Placement.Kind, zipURL: URL,
                sha256: String, productIDs: [String] = []) {
        self.placementID = placementID
        self.kind = kind
        self.zipURL = zipURL
        self.sha256 = sha256
        self.productIDs = productIDs
    }
}
