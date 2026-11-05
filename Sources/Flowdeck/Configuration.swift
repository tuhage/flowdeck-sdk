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
    /// Optional allowlisted origins tried in order when `baseURL` cannot serve the manifest or live page.
    public let fallbackOrigins: [URL]

    public init(apiKey: String, baseURL: URL, protocolClasses: [URLProtocol.Type] = [],
                fallbackPackages: [FlowdeckFallbackPackage] = [],
                cacheDirectory: URL? = nil, appAccountToken: UUID? = nil,
                fallbackOrigins: [URL] = []) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.protocolClasses = protocolClasses
        self.fallbackPackages = fallbackPackages
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Flowdeck", isDirectory: true)
        self.appAccountToken = appAccountToken
        self.fallbackOrigins = fallbackOrigins
    }

    static func validOrigin(_ url: URL) -> Bool {
        let local = ["localhost", "127.0.0.1", "[::1]"].contains(url.host ?? "")
        return url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && (url.path.isEmpty || url.path == "/")
            && (url.scheme == "https" || (local && url.scheme == "http"))
    }

    private static func originKey(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    func validate() throws {
        let origins = [baseURL] + fallbackOrigins
        guard !apiKey.isEmpty, !apiKey.contains("\n"), !apiKey.contains("\r"),
              origins.allSatisfy(Self.validOrigin),
              Set(origins.map(Self.originKey)).count == origins.count,
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
