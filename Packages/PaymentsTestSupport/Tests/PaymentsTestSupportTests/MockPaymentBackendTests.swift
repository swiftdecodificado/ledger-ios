import Foundation
import Testing
import Payments
@testable import PaymentsTestSupport

private let request = PaymentRequest(cents: 12_500, destinationAccountID: "account-42")

@Test
func sameKeyAndSameRequestProduceOneDebit() async throws {
    let backend = MockPaymentBackend()

    let first = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")
    let second = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")

    #expect(first.body == second.body)
    #expect(!first.isReplay)
    #expect(second.isReplay)
    #expect(await backend.ledgerEntries.count == 1)
}

@Test
func sameKeyWithDifferentAmountIsRejected() async throws {
    let backend = MockPaymentBackend()
    _ = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")

    await #expect(throws: MockPaymentBackend.Failure.idempotencyKeyReusedWithDifferentRequest) {
        try await backend.createPayment(
            request: PaymentRequest(cents: 99_900, destinationAccountID: "account-42"),
            idempotencyKey: "payment-intent-42"
        )
    }
    #expect(await backend.ledgerEntries.count == 1)
}

@Test
func differentKeysAreDifferentPayments() async throws {
    let backend = MockPaymentBackend()

    let first = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")
    let second = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-43")

    #expect(first.body != second.body)
    #expect(await backend.ledgerEntries.count == 2)
}

@Test
func concurrentRequestsWithTheSameKeyDebitOnce() async throws {
    let backend = MockPaymentBackend(configuration: .init(processingDelay: .milliseconds(200)))

    async let first = Result { try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42") }
    async let second = Result { try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42") }
    let results = await [first, second]

    let succeeded = results.filter { (try? $0.get()) != nil }
    let inProgress = results.filter {
        if case .failure(MockPaymentBackend.Failure.requestInProgress) = $0 { return true }
        return false
    }
    #expect(succeeded.count == 1)
    #expect(inProgress.count == 1)
    #expect(await backend.ledgerEntries.count == 1)
}

@Test
func declineIsStoredAndReplayed() async throws {
    let backend = MockPaymentBackend(configuration: .init(amountLimitCents: 10_000))

    let first = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")
    let second = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")

    #expect(first.statusCode == 402)
    #expect(second.statusCode == 402)
    #expect(second.isReplay)
    #expect(await backend.ledgerEntries.isEmpty)
}

@Test
func crashBeforeCommitLeavesNoDebitAndTheLeaseFreesTheKey() async throws {
    let clock = TestClock()
    let backend = MockPaymentBackend(configuration: .init(processingLease: 30), now: clock.now)
    await backend.crashBeforeNextCommit()

    await #expect(throws: MockPaymentBackend.Failure.crashedBeforeCommit) {
        try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")
    }
    #expect(await backend.ledgerEntries.isEmpty)
    #expect(await backend.attemptStatus(idempotencyKey: "payment-intent-42") == .processing)

    clock.advance(by: 31)

    #expect(await backend.attemptStatus(idempotencyKey: "payment-intent-42") == nil)
    let retry = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")
    #expect(retry.statusCode == 201)
    #expect(await backend.ledgerEntries.count == 1)
}

@Test
func executionThatLostItsLeaseDoesNotDebit() async throws {
    let clock = TestClock()
    let backend = MockPaymentBackend(
        configuration: .init(processingDelay: .milliseconds(300), processingLease: 30),
        now: clock.now
    )

    // The first execution is still working when its lease runs out and a retry takes the key over.
    async let slow = Result { try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42") }
    try await Task.sleep(for: .milliseconds(50))
    clock.advance(by: 31)
    let takeover = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")

    let original = await slow
    #expect(takeover.statusCode == 201)
    #expect(throws: MockPaymentBackend.Failure.requestInProgress) { try original.get() }
    #expect(await backend.ledgerEntries.count == 1)
}

@Test
func keyExpiresAfterTheRetentionPeriodAndIsNotProcessedAgain() async throws {
    let clock = TestClock()
    let backend = MockPaymentBackend(configuration: .init(keyRetention: 24 * 60 * 60), now: clock.now)
    _ = try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")

    clock.advance(by: 24 * 60 * 60)

    #expect(await backend.attemptStatus(idempotencyKey: "payment-intent-42") == .expired)
    await #expect(throws: MockPaymentBackend.Failure.idempotencyKeyExpired) {
        try await backend.createPayment(request: request, idempotencyKey: "payment-intent-42")
    }
    #expect(await backend.ledgerEntries.count == 1)
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: @Sendable () -> Date {
        { [self] in lock.withLock { current } }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
