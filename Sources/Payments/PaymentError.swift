public enum PaymentError: Error, Equatable, Sendable {
    /// No usable answer arrived: timeout, lost connection, 5xx, an unreadable 2xx, 409 because
    /// another request with the same key is still being processed, or 410 because the key expired.
    /// The server may or may not have debited, so this is not a failure.
    case outcomeUnknown

    /// 422: the key was already used with a different amount or destination.
    case idempotencyKeyReusedWithDifferentRequest

    /// Any other 4xx: the server answered and did not create the payment.
    case rejected(statusCode: Int)
}
