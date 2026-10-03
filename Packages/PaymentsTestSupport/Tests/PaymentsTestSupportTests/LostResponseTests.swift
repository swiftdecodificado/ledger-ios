import Foundation
import Testing
import Payments
import PaymentsTestSupport

// The article's scenario end to end: PaymentClient → HTTPPaymentTransport → mock server.
private let baseURL = URL(string: "https://mock.payments.local/v1")!

private func makeClient(_ server: MockPaymentHTTPServer) -> PaymentClient {
    PaymentClient(transport: HTTPPaymentTransport(baseURL: baseURL, httpClient: server))
}

private func makeIntent(key: String) -> PaymentIntent {
    PaymentIntent(idempotencyKey: key, cents: 12_500, destinationAccountID: "account-42")
}

@Test
func statusAfterLostResponseFindsTheFirstPayment() async throws {
    let server = MockPaymentHTTPServer(nextFault: .loseResponse)
    let client = makeClient(server)
    let intent = makeIntent(key: "payment-intent-42")

    await #expect(throws: PaymentError.outcomeUnknown) {
        try await client.createPayment(intent)
    }
    // The client saw a timeout, but the debit already happened.
    #expect(await server.backend.ledgerEntries.count == 1)

    let status = try await client.status(of: intent)

    #expect(
        status == .succeeded(
            Payment(id: "pay_1", cents: 12_500, destinationAccountID: "account-42")
        )
    )
    #expect(await server.receivedIdempotencyKeys == ["payment-intent-42"])
    #expect(await server.backend.ledgerEntries.count == 1)
}

@Test
func retryAfterLostResponseReturnsTheFirstPayment() async throws {
    let server = MockPaymentHTTPServer(nextFault: .loseResponse)
    let client = makeClient(server)
    let intent = makeIntent(key: "payment-intent-42")

    _ = try? await client.createPayment(intent)
    let payment = try await client.createPayment(intent)

    #expect(payment.id == "pay_1")
    #expect(await server.backend.ledgerEntries.count == 1)
}

@Test
func retryWithANewKeyDebitsTwice() async throws {
    let server = MockPaymentHTTPServer(nextFault: .loseResponse)
    let client = makeClient(server)

    _ = try? await client.createPayment(makeIntent(key: "payment-intent-42"))
    _ = try await client.createPayment(makeIntent(key: "payment-intent-43"))

    #expect(await server.backend.ledgerEntries.count == 2)
}

@Test
func crashBeforeCommitIsFoundAsProcessingAndThenFree() async throws {
    let server = MockPaymentHTTPServer(
        backend: MockPaymentBackend(configuration: .init(processingLease: 0)),
        nextFault: .crashBeforeCommit
    )
    let client = makeClient(server)
    let intent = makeIntent(key: "payment-intent-42")

    await #expect(throws: PaymentError.outcomeUnknown) {
        try await client.createPayment(intent)
    }
    #expect(await server.backend.ledgerEntries.isEmpty)
    // With a zero lease the abandoned reservation is already free.
    #expect(try await client.status(of: intent) == .notFound)

    _ = try await client.createPayment(intent)
    #expect(await server.backend.ledgerEntries.count == 1)
}

@Test
func failureAfterCommitIsFoundAsSucceeded() async throws {
    let server = MockPaymentHTTPServer(nextFault: .failAfterCommit)
    let client = makeClient(server)
    let intent = makeIntent(key: "payment-intent-42")

    await #expect(throws: PaymentError.outcomeUnknown) {
        try await client.createPayment(intent)
    }

    guard case .succeeded = try await client.status(of: intent) else {
        Issue.record("expected succeeded")
        return
    }
    #expect(await server.backend.ledgerEntries.count == 1)
}

@Test
func expiredKeyIsReportedAndNotDebitedAgain() async throws {
    let clock = TestClock()
    let server = MockPaymentHTTPServer(
        backend: MockPaymentBackend(configuration: .init(keyRetention: 24 * 60 * 60), now: clock.now),
        nextFault: .loseResponse
    )
    let client = makeClient(server)
    let intent = makeIntent(key: "payment-intent-42")

    _ = try? await client.createPayment(intent)
    clock.advance(by: 24 * 60 * 60)

    // The first payment completed, but its result is gone: the client must not treat this as notFound.
    #expect(try await client.status(of: intent) == .expired)
    await #expect(throws: PaymentError.outcomeUnknown) {
        try await client.createPayment(intent)
    }
    #expect(await server.backend.ledgerEntries.count == 1)
}
