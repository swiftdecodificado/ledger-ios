import Foundation
import Testing
@testable import Payments

final class SpyTransport: PaymentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CreatePaymentRequest] = []

    var requests: [CreatePaymentRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: CreatePaymentRequest) async throws -> Payment {
        lock.withLock { recorded.append(request) }
        return Payment(id: "pay_1", cents: request.body.cents, destinationAccountID: request.body.destinationAccountID)
    }

    func status(idempotencyKey: String) async throws -> PaymentStatus {
        .notFound
    }
}

@Test
func retryReusesTheSameIdempotencyKey() async throws {
    let transport = SpyTransport()
    let client = PaymentClient(transport: transport)

    let intent = PaymentIntent(
        idempotencyKey: "payment-intent-42",
        cents: 12_500,
        destinationAccountID: "account-42"
    )

    _ = try await client.createPayment(intent)
    _ = try await client.createPayment(intent)

    #expect(transport.requests.map(\.idempotencyKey) == [
        "payment-intent-42",
        "payment-intent-42",
    ])
}

@Test
func requestCarriesTheIntentAmountAndDestination() async throws {
    let transport = SpyTransport()
    let client = PaymentClient(transport: transport)

    _ = try await client.createPayment(
        PaymentIntent(idempotencyKey: "k", cents: 12_500, destinationAccountID: "account-42")
    )

    #expect(transport.requests.map(\.body) == [PaymentRequest(cents: 12_500, destinationAccountID: "account-42")])
}
