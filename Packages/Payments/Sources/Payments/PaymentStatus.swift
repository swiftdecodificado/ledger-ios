/// What the server knows about one idempotency key, from `GET /payment-attempts/{key}`.
public enum PaymentStatus: Equatable, Sendable {
    /// Nothing was debited with this key: the request never arrived, or it was abandoned before committing.
    /// A `POST` with the same key is safe: if the original arrives later, the key still protects it.
    case notFound

    /// The key existed, but its result was discarded after the retention period. The payment may have
    /// completed, so sending it again is not safe.
    case expired

    /// A request with this key is being processed right now.
    case processing

    case succeeded(Payment)

    /// The server answered the original request with a definitive refusal.
    case declined(code: String)
}
