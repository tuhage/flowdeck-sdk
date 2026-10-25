import Foundation
import StoreKit

public enum FlowdeckEvent: Sendable {
    case loaded(FlowdeckContent)
    case bridge(placementID: String, response: FlowdeckBridgeResponse)
    case event(placementID: String, name: String, props: [String: JSONValue])
    case onboardingCompleted(placementID: String)
    case closed(placementID: String)
    case entitlementsChanged([FlowdeckEntitlement])
    case failed(placementID: String, message: String)
}

/// Keep one instance alive for the app's lifetime to observe StoreKit updates.
@MainActor
public final class Flowdeck {
    public static let version = "0.1.0"
    public var onEvent: ((FlowdeckEvent) -> Void)?
    private let repository: ContentRepository
    let commerce: any Commerce
    private var transactionUpdates: Task<Void, Never>?
    private var observers: [UUID: (FlowdeckEvent) -> Void] = [:]

    public init(configuration: FlowdeckConfiguration, onEvent: ((FlowdeckEvent) -> Void)? = nil) throws {
        repository = try ContentRepository(configuration: configuration)
        commerce = StoreKitService(appAccountToken: configuration.appAccountToken)
        self.onEvent = onEvent
        transactionUpdates = Task { [weak self] in
            for await verification in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = verification else { continue }
                await transaction.finish()
                guard let self else { return }
                self.emit(.entitlementsChanged(await self.commerce.entitlements()))
            }
        }
    }

    deinit { transactionUpdates?.cancel() }

    func emit(_ event: FlowdeckEvent) {
        onEvent?(event)
        for observer in Array(observers.values) { observer(event) }
    }

    func observe(_ observer: @escaping (FlowdeckEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Refresh the published list using ETag. Throws on network failure; prepare uses offline fallbacks.
    public func refreshPlacements() async throws -> [Placement] { try await repository.refresh() }

    public func prepare(placementID: String) async throws -> FlowdeckContent {
        do { return try await repository.resolve(placementID) }
        catch {
            emit(.failed(placementID: placementID, message: error.localizedDescription))
            throw error
        }
    }

    public func currentEntitlements() async -> [FlowdeckEntitlement] { await commerce.entitlements() }
}
