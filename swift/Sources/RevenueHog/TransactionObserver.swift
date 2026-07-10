#if canImport(StoreKit)
import Foundation
import StoreKit

/// Watches StoreKit 2 and reports attribution for every verified
/// transaction — current entitlements once at launch (so existing
/// subscribers attribute immediately), then the live `updates` stream.
/// Already-reported transactions are deduped by the client, and the
/// backend endpoint is idempotent anyway.
enum TransactionObserver {
    static func start(client: HogClient) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            for await result in Transaction.currentEntitlements {
                await report(result, to: client)
            }
            for await result in Transaction.updates {
                await report(result, to: client)
            }
        }
    }

    private static func report(
        _ result: VerificationResult<Transaction>, to client: HogClient
    ) async {
        guard case .verified(let transaction) = result else { return }
        await client.attribute(
            originalTransactionId: String(transaction.originalID),
            productId: transaction.productID
        )
    }
}
#endif
