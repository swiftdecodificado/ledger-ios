/// Names and bodies shared by the client and the mock server. `openapi.yaml` is the reference.
public enum PaymentsAPI {
    public static let idempotencyKeyHeader = "Idempotency-Key"
    public static let replayedHeader = "Idempotent-Replayed"
    public static let paymentsPath = "payments"
    public static let attemptsPath = "payment-attempts"
}

/// `{"error":{"code":"…","message":"…"}}`, the body of every error response.
public struct APIErrorResponse: Codable, Equatable, Sendable {
    public struct Detail: Codable, Equatable, Sendable {
        public let code: String
        public let message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    public let error: Detail

    public init(code: String, message: String) {
        error = Detail(code: code, message: message)
    }
}

/// Body of `GET /payment-attempts/{key}` when the key is known.
public struct PaymentAttemptResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case processing
        case succeeded
        case declined
    }

    public let status: Status
    public let payment: Payment?
    public let error: APIErrorResponse.Detail?

    public init(status: Status, payment: Payment? = nil, error: APIErrorResponse.Detail? = nil) {
        self.status = status
        self.payment = payment
        self.error = error
    }
}
