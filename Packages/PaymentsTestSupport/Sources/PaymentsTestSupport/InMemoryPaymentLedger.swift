import Foundation
import Payments

public struct LedgerEntry: Equatable, Sendable {
    public let paymentID: String
    public let cents: Int
    public let destinationAccountID: String
}

/// What the server stores for a key: the status and body it answered the first time,
/// so a retry gets exactly the same response.
struct PaymentResult: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case payment(Payment)
        case error(APIErrorResponse)
    }

    let statusCode: Int
    let body: Body

    /// Set on the copy returned to a retry; not part of what is stored.
    var isReplay = false
}

/// Every call is one debit. Protection against duplicates lives in `MockPaymentBackend`, not here.
struct InMemoryPaymentLedger {
    private(set) var entries: [LedgerEntry] = []

    mutating func debit(_ request: PaymentRequest) -> PaymentResult {
        let payment = Payment(
            id: "pay_\(entries.count + 1)",
            cents: request.cents,
            destinationAccountID: request.destinationAccountID
        )
        entries.append(
            LedgerEntry(paymentID: payment.id, cents: payment.cents, destinationAccountID: payment.destinationAccountID)
        )
        return PaymentResult(statusCode: 201, body: .payment(payment))
    }
}

extension PaymentRequest {
    /// Every field of the body, in a stable order. The same key with a different fingerprint
    /// is a different payment hiding behind a reused key.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
