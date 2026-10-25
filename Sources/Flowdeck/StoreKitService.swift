import Foundation
import StoreKit

public struct FlowdeckProduct: Codable, Sendable {
    public struct Period: Codable, Sendable, Equatable {
        public let value: Int
        public let unit: String
        init(_ period: Product.SubscriptionPeriod) {
            value = period.value
            unit = switch period.unit {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            @unknown default: "unknown"
            }
        }
    }
    public struct IntroductoryOffer: Codable, Sendable {
        public let displayPrice: String
        public let price: String
        public let paymentMode: String
        public let period: Period
        public let periodCount: Int
    }
    public let id: String
    public let displayName: String
    public let description: String
    public let displayPrice: String
    public let price: String
    public let currencyCode: String
    public let type: String
    public let subscriptionPeriod: Period?
    public let introductoryOffer: IntroductoryOffer?
    public let isEligibleForIntroOffer: Bool

    init(_ product: Product) async {
        id = product.id
        displayName = product.displayName
        description = product.description
        displayPrice = product.displayPrice
        price = NSDecimalNumber(decimal: product.price).stringValue
        currencyCode = product.priceFormatStyle.currencyCode
        type = product.type.rawValue
        subscriptionPeriod = product.subscription.map { Period($0.subscriptionPeriod) }
        if let offer = product.subscription?.introductoryOffer {
            let mode: String = switch offer.paymentMode {
            case .freeTrial: "freeTrial"
            case .payAsYouGo: "payAsYouGo"
            case .payUpFront: "payUpFront"
            default: "unknown"
            }
            introductoryOffer = IntroductoryOffer(displayPrice: offer.displayPrice,
                price: NSDecimalNumber(decimal: offer.price).stringValue, paymentMode: mode,
                period: Period(offer.period), periodCount: offer.periodCount)
            isEligibleForIntroOffer = await product.subscription?.isEligibleForIntroOffer ?? false
        } else {
            introductoryOffer = nil
            isEligibleForIntroOffer = false
        }
    }
}

public struct FlowdeckEntitlement: Codable, Sendable, Equatable {
    public let productID: String
    /// Strings avoid JavaScript's integer precision limit.
    public let transactionID: String
    public let originalTransactionID: String
    public let expirationDate: Date?

    init(_ transaction: Transaction) {
        productID = transaction.productID
        transactionID = String(transaction.id)
        originalTransactionID = String(transaction.originalID)
        expirationDate = transaction.expirationDate
    }
}

public struct FlowdeckPurchaseResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case purchased, cancelled, pending }
    public let status: Status
    public let transaction: FlowdeckEntitlement?
    public let entitlements: [FlowdeckEntitlement]
}

@MainActor
protocol Commerce: AnyObject {
    func products(ids: [String]) async throws -> [FlowdeckProduct]
    func purchase(productID: String) async throws -> FlowdeckPurchaseResult
    func restore() async throws -> [FlowdeckEntitlement]
    func entitlements() async -> [FlowdeckEntitlement]
}

@MainActor
final class StoreKitService: Commerce {
    private let appAccountToken: UUID?
    private var busy = false

    init(appAccountToken: UUID? = nil) { self.appAccountToken = appAccountToken }

    func products(ids: [String]) async throws -> [FlowdeckProduct] {
        let products = try await Product.products(for: ids)
        var result: [FlowdeckProduct] = []
        for id in ids {
            if let product = products.first(where: { $0.id == id }) { result.append(await FlowdeckProduct(product)) }
        }
        return result
    }

    func purchase(productID: String) async throws -> FlowdeckPurchaseResult {
        guard !busy else { throw FlowdeckError.purchaseInProgress }
        busy = true
        defer { busy = false }
        guard let product = try await Product.products(for: [productID]).first else {
            throw FlowdeckError.productUnavailable
        }
        let options: Set<Product.PurchaseOption> = appAccountToken.map { [.appAccountToken($0)] } ?? []
        switch try await product.purchase(options: options) {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw FlowdeckError.unverifiedTransaction }
            let value = FlowdeckEntitlement(transaction)
            await transaction.finish()
            return FlowdeckPurchaseResult(status: .purchased, transaction: value, entitlements: await entitlements())
        case .userCancelled:
            return FlowdeckPurchaseResult(status: .cancelled, transaction: nil, entitlements: await entitlements())
        case .pending:
            return FlowdeckPurchaseResult(status: .pending, transaction: nil, entitlements: await entitlements())
        @unknown default:
            throw FlowdeckError.invalidResponse
        }
    }

    func restore() async throws -> [FlowdeckEntitlement] {
        guard !busy else { throw FlowdeckError.purchaseInProgress }
        busy = true
        defer { busy = false }
        try await AppStore.sync()
        return await entitlements()
    }

    func entitlements() async -> [FlowdeckEntitlement] {
        var values: [FlowdeckEntitlement] = []
        for await verification in Transaction.currentEntitlements {
            guard case .verified(let transaction) = verification, transaction.revocationDate == nil,
                  !transaction.isUpgraded,
                  transaction.expirationDate.map({ $0 > Date() }) ?? true else { continue }
            values.append(FlowdeckEntitlement(transaction))
        }
        return values.sorted { $0.productID < $1.productID }
    }
}
