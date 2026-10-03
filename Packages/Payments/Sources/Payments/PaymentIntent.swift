/// One payment the person confirmed. Every attempt to complete it carries the same key;
/// a genuinely new payment gets a new intent and a new key.
public struct PaymentIntent: Sendable {
    public let idempotencyKey: String
    public let cents: Int
    public let destinationAccountID: String

    public init(idempotencyKey: String, cents: Int, destinationAccountID: String) {
        self.idempotencyKey = idempotencyKey
        self.cents = cents
        self.destinationAccountID = destinationAccountID
    }
}

extension PaymentIntent: Equatable {}
