import Foundation

enum LivePage {
    static func url(baseURL: URL, appID: String, placementID: String) throws -> URL {
        guard Placement.validID(appID), Placement.validID(placementID) else {
            throw FlowdeckError.invalidManifest
        }
        return baseURL.appendingPathComponent("live/\(appID)/\(placementID)/")
    }

    static func allows(_ candidate: URL?, trusted: URL) -> Bool {
        guard let candidate, !candidate.isFileURL,
              candidate.user == nil, candidate.password == nil,
              candidate.scheme == trusted.scheme,
              candidate.host?.lowercased() == trusted.host?.lowercased(),
              port(candidate) == port(trusted),
              let path = URLComponents(url: candidate, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let root = URLComponents(url: trusted, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              path == root else { return false }
        return true
    }

    private static func port(_ url: URL) -> Int {
        url.port ?? (url.scheme == "https" ? 443 : 80)
    }
}
