public protocol PaymentTransport: Sendable {
    func send(_ request: CreatePaymentRequest) async throws -> Payment
    func status(idempotencyKey: String) async throws -> PaymentStatus
}

/// The app's entry point for payments. It never creates keys: the caller owns the intent,
/// so retrying or checking the same intent uses the same key.
public struct PaymentClient: Sendable {
    private let transport: any PaymentTransport

    public init(transport: any PaymentTransport) {
        self.transport = transport
    }

    public func createPayment(_ intent: PaymentIntent) async throws -> Payment {
        try await transport.send(CreatePaymentRequest(intent: intent))
    }

    public func status(of intent: PaymentIntent) async throws -> PaymentStatus {
        try await transport.status(idempotencyKey: intent.idempotencyKey)
    }
}
