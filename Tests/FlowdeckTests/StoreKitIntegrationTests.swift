#if os(iOS)
import StoreKit
import StoreKitTest
import XCTest
@testable import Flowdeck

final class StoreKitIntegrationTests: XCTestCase {
    // One session/test: StoreKit's test storefront is process-wide.
    @MainActor
    func testPurchaseRestoreOffersPendingAndRevocation() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Products", withExtension: "storekit", subdirectory: "Fixtures"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let token = UUID()
        let commerce = StoreKitService(appAccountToken: token)
        let ids = ["pro.weekly", "pro.weekly.payg", "pro.monthly", "pro.monthly.payg", "pro.yearly", "pro.yearly.payg"]
        let products = try await commerce.products(ids: ids)
        XCTAssertEqual(products.count, 6)
        let weekly = try XCTUnwrap(products.first(where: { $0.id == "pro.weekly" }))
        XCTAssertEqual(weekly.price, "6.99")
        XCTAssertEqual(weekly.currencyCode, "USD")
        XCTAssertFalse(weekly.displayPrice.isEmpty)
        XCTAssertTrue(weekly.isEligibleForIntroOffer)
        XCTAssertEqual(weekly.introductoryOffer?.paymentMode, "freeTrial")
        XCTAssertEqual(weekly.introductoryOffer?.period.value, 3)
        XCTAssertEqual(weekly.introductoryOffer?.period.unit, "day")
        for (id, unit, price) in [("pro.weekly.payg", "week", "0.99"), ("pro.monthly.payg", "month", "3.99"), ("pro.yearly.payg", "year", "29.99")] {
            let product = try XCTUnwrap(products.first(where: { $0.id == id }))
            XCTAssertEqual(product.introductoryOffer?.paymentMode, "payAsYouGo")
            XCTAssertEqual(product.introductoryOffer?.period.unit, unit)
            XCTAssertEqual(product.introductoryOffer?.periodCount, 1)
            XCTAssertEqual(product.introductoryOffer?.price, price)
        }
        let empty = try await commerce.restore()
        XCTAssertTrue(empty.isEmpty)
        let purchased = try await commerce.purchase(productID: "pro.weekly")
        XCTAssertEqual(purchased.status, .purchased)
        XCTAssertEqual(purchased.transaction?.productID, "pro.weekly")
        XCTAssertEqual(purchased.entitlements.map(\.productID), ["pro.weekly"])
        let freshService = StoreKitService()
        let restored = try await freshService.restore()
        XCTAssertEqual(restored.map(\.productID), ["pro.weekly"])
        XCTAssertEqual(restored.first?.transactionID, purchased.transaction?.transactionID)
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result { XCTAssertEqual(transaction.appAccountToken, token) }
        }
        let afterPurchase = try await commerce.products(ids: ["pro.weekly"])
        XCTAssertFalse(try XCTUnwrap(afterPurchase.first).isEligibleForIntroOffer)
        let transactionID = try XCTUnwrap(session.allTransactions().first?.identifier)
        try session.refundTransaction(identifier: transactionID)
        let revoked = await commerce.entitlements()
        XCTAssertTrue(revoked.isEmpty)

        session.clearTransactions()
        session.askToBuyEnabled = true
        let update = expectation(description: "SDK reports delayed purchase approval")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sdk = try Flowdeck(configuration: .init(apiKey: "test", baseURL: URL(string: "http://127.0.0.1:9")!,
            cacheDirectory: directory)) { event in
            if case .entitlementsChanged(let values) = event, values.contains(where: { $0.productID == "pro.monthly" }) {
                update.fulfill()
            }
        }
        let pending = try await commerce.purchase(productID: "pro.monthly")
        XCTAssertEqual(pending.status, .pending)
        XCTAssertNil(pending.transaction)
        XCTAssertTrue(pending.entitlements.isEmpty)
        let pendingID = try XCTUnwrap(session.allTransactions().first?.identifier)
        try session.approveAskToBuyTransaction(identifier: pendingID)
        await fulfillment(of: [update], timeout: 10)
        let approved = await sdk.currentEntitlements()
        XCTAssertEqual(approved.map(\.productID), ["pro.monthly"])
        try session.expireSubscription(productIdentifier: "pro.monthly")
        let expired = await commerce.entitlements()
        XCTAssertTrue(expired.isEmpty)

        if #available(iOS 17.0, *) {
            session.clearTransactions()
            session.askToBuyEnabled = false
            try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
            let cancelled = try await commerce.purchase(productID: "pro.yearly")
            XCTAssertEqual(cancelled.status, .cancelled)
            XCTAssertNil(cancelled.transaction)
            try await session.setSimulatedError(nil, forAPI: .purchase)
            try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
            do { _ = try await commerce.restore(); XCTFail("Restore should surface the StoreKit error") }
            catch { /* Expected: a restore failure must not be reported as success. */ }
            try await session.setSimulatedError(nil, forAPI: .appStoreSync)
            let recovery = try await commerce.restore()
            XCTAssertTrue(recovery.isEmpty)
        }
    }
}
#endif
