import Foundation
import Payments

/// In-memory server side of the idempotency contract in `openapi.yaml`.
public actor MockPaymentBackend {
    public struct Configuration: Sendable {
        /// Simulated work between reserving the key and committing the result.
        public var processingDelay: Duration
        /// How long a reservation without a result is honored. After that, the attempt is considered
        /// abandoned (the process died) and the key can be processed again. Must exceed `processingDelay`.
        public var processingLease: TimeInterval
        /// How long the result of a completed key is kept. After that, the key is remembered as expired
        /// and never processed again.
        public var keyRetention: TimeInterval
        /// Amounts above this are declined: a definitive refusal that is stored and replayed.
        public var amountLimitCents: Int

        public init(
            processingDelay: Duration = .zero,
            processingLease: TimeInterval = 30,
            keyRetention: TimeInterval = 24 * 60 * 60,
            amountLimitCents: Int = 1_000_000
        ) {
            self.processingDelay = processingDelay
            self.processingLease = processingLease
            self.keyRetention = keyRetention
            self.amountLimitCents = amountLimitCents
        }
    }

    enum Failure: Error, Equatable {
        case idempotencyKeyReusedWithDifferentRequest
        case requestInProgress
        /// The key is past its retention period. Its result is gone, and it is not processed again.
        case idempotencyKeyExpired
        /// The simulated process died before committing. Nothing was debited.
        case crashedBeforeCommit
    }

    enum AttemptStatus: Equatable {
        case processing
        case completed(PaymentResult)
        case expired
    }

    private struct PaymentAttempt {
        enum State {
            case processing(owner: UUID, leaseExpiresAt: Date)
            case completed(PaymentResult, completedAt: Date)
            /// Only the fact that the key existed is kept, so a late retry cannot debit again.
            case expired
        }

        let requestFingerprint: String
        var state: State
    }

    private var paymentAttempts: [String: PaymentAttempt] = [:]
    private var ledger = PaymentLedger()
    private var crashesBeforeNextCommit = false
    private let configuration: Configuration
    private let now: @Sendable () -> Date

    public init(configuration: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
    }

    public var ledgerEntries: [LedgerEntry] {
        ledger.entries
    }

    /// The next request reserves its key and then dies before the commit, like a process crash:
    /// no debit, no result, and the reservation stays until its lease expires.
    func crashBeforeNextCommit() {
        crashesBeforeNextCommit = true
    }

    func createPayment(
        request: PaymentRequest,
        idempotencyKey: String
    ) async throws -> PaymentResult {
        if let previous = liveAttempt(for: idempotencyKey) {
            if case .expired = previous.state {
                throw Failure.idempotencyKeyExpired
            }
            guard previous.requestFingerprint == request.fingerprint else {
                throw Failure.idempotencyKeyReusedWithDifferentRequest
            }
            switch previous.state {
            case .processing:
                throw Failure.requestInProgress
            case .completed(var result, _):
                result.isReplay = true
                return result
            case .expired:
                throw Failure.idempotencyKeyExpired
            }
        }

        // The check above and this reservation run without a suspension point in between, so two
        // requests with the same key cannot both get past it. A real backend gets the same guarantee
        // from a unique constraint on the key.
        let owner = UUID()
        paymentAttempts[idempotencyKey] = PaymentAttempt(
            requestFingerprint: request.fingerprint,
            state: .processing(owner: owner, leaseExpiresAt: now().addingTimeInterval(configuration.processingLease))
        )

        if configuration.processingDelay > .zero {
            // A client giving up does not stop the server: the work continues.
            try? await Task.sleep(for: configuration.processingDelay)
        }

        if crashesBeforeNextCommit {
            crashesBeforeNextCommit = false
            throw Failure.crashedBeforeCommit
        }

        // Only the owner of the reservation may commit. If the lease expired and another request took
        // the key over, this one stops here instead of debiting a second time.
        guard
            case .processing(let currentOwner, _) = paymentAttempts[idempotencyKey]?.state,
            currentOwner == owner
        else {
            throw Failure.requestInProgress
        }

        // Commit: the decision, the debit and the stored result happen together, as in one database
        // transaction. There is no state where the money moved and the key has no result.
        let result = request.cents > configuration.amountLimitCents
            ? PaymentResult(
                statusCode: 402,
                body: .error(APIErrorResponse(code: "amount_exceeds_limit", message: "Valor acima do limite."))
            )
            : ledger.debit(request)
        paymentAttempts[idempotencyKey]?.state = .completed(result, completedAt: now())
        return result
    }

    func attemptStatus(idempotencyKey: String) -> AttemptStatus? {
        switch liveAttempt(for: idempotencyKey)?.state {
        case .processing:
            .processing
        case .completed(let result, _):
            .completed(result)
        case .expired:
            .expired
        case nil:
            nil
        }
    }

    /// The attempt for a key, after dropping an abandoned reservation and expiring a result past retention.
    private func liveAttempt(for idempotencyKey: String) -> PaymentAttempt? {
        guard var attempt = paymentAttempts[idempotencyKey] else { return nil }
        switch attempt.state {
        case .processing(_, let leaseExpiresAt) where leaseExpiresAt <= now():
            // Nothing was debited, so the key is free again.
            paymentAttempts[idempotencyKey] = nil
            return nil
        case .completed(_, let completedAt) where completedAt.addingTimeInterval(configuration.keyRetention) <= now():
            attempt.state = .expired
            paymentAttempts[idempotencyKey] = attempt
        default:
            break
        }
        return attempt
    }
}
