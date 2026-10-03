/// JSON body of `POST /payments`. The idempotency key travels in the `Idempotency-Key` header.
public struct PaymentRequest: Codable, Equatable, Sendable {
    public let cents: Int
    public let destinationAccountID: String

    public init(cents: Int, destinationAccountID: String) {
        self.cents = cents
        self.destinationAccountID = destinationAccountID
    }
}

/// What a transport receives: the body plus the key that ties it to one intent.
public struct CreatePaymentRequest: Equatable, Sendable {
    public let idempotencyKey: String
    public let body: PaymentRequest

    public init(intent: PaymentIntent) {
        idempotencyKey = intent.idempotencyKey
        body = PaymentRequest(cents: intent.cents, destinationAccountID: intent.destinationAccountID)
    }
}
