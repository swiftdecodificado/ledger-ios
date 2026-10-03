import Foundation
import Payments
import PaymentsTestSupport
import Testing
import UIKit
@testable import Ledger

@MainActor
struct PaymentViewControllerTests {
    @Test
    func buttonStaysDisabledWhileTheRequestIsPending() async throws {
        let transport = GatedTransport()
        let screen = Screen(client: PaymentClient(transport: transport))

        screen.tapPay()
        try await waitUntil { transport.requests.count == 1 }

        #expect(!screen.payButton.isEnabled)
        #expect(screen.status.hasPrefix("Enviando pagamento"))

        transport.open()
        try await waitUntil { screen.status.hasPrefix("Pagamento confirmado") }
        #expect(transport.requests.count == 1)
    }

    @Test
    func recoveryAfterAnUnknownOutcomeChecksTheStatus() async throws {
        let server = MockPaymentHTTPServer(nextFault: .loseResponse)
        let screen = Screen(server: server)

        screen.tapPay()
        try await waitUntil { screen.payButton.isEnabled }

        #expect(screen.status.hasPrefix("Não foi possível confirmar o pagamento"))
        #expect(screen.payButton.configuration?.title == "Verificar pagamento")
        #expect(await server.backend.ledgerEntries.count == 1)

        screen.tapPay()
        try await waitUntil { screen.status == "Pagamento confirmado: pay_1" }

        // The recovery asked about the key and found the payment: no second POST.
        #expect(await server.receivedIdempotencyKeys.count == 1)
        #expect(await server.receivedStatusQueries.count == 1)
        #expect(await server.backend.ledgerEntries.count == 1)
    }

    @Test
    func recoveryResubmitsWithTheSameKeyWhenTheServerHasNoAttempt() async throws {
        // The server died before committing and the reservation already expired.
        let server = MockPaymentHTTPServer(
            backend: MockPaymentBackend(configuration: .init(processingLease: 0)),
            nextFault: .crashBeforeCommit
        )
        let screen = Screen(server: server)

        screen.tapPay()
        try await waitUntil { screen.payButton.isEnabled }
        #expect(await server.backend.ledgerEntries.isEmpty)

        screen.tapPay()
        try await waitUntil { screen.status == "Pagamento confirmado: pay_1" }

        let keys = await server.receivedIdempotencyKeys
        #expect(keys.count == 2)
        #expect(Set(keys).count == 1)
        #expect(await server.receivedStatusQueries.count == 1)
        #expect(await server.backend.ledgerEntries.count == 1)
    }

    @Test
    func recoveryWaitsWhileTheAttemptIsStillProcessing() async throws {
        let server = MockPaymentHTTPServer(nextFault: .crashBeforeCommit)
        let screen = Screen(server: server)

        screen.tapPay()
        try await waitUntil { screen.payButton.isEnabled }

        screen.tapPay()
        try await waitUntil { screen.status == "O pagamento ainda está em processamento." }

        #expect(screen.payButton.isEnabled)
        #expect(await server.receivedIdempotencyKeys.count == 1)
        #expect(await server.backend.ledgerEntries.isEmpty)
    }

    @Test
    func recoveryStopsWithoutResendingWhenTheKeyExpired() async throws {
        // The first payment completed, and its result is already past retention when the recovery asks.
        let server = MockPaymentHTTPServer(
            backend: MockPaymentBackend(configuration: .init(keyRetention: 0)),
            nextFault: .loseResponse
        )
        let screen = Screen(server: server)

        screen.tapPay()
        try await waitUntil { screen.payButton.isEnabled }

        screen.tapPay()
        try await waitUntil { screen.status.hasPrefix("Não é mais possível confirmar este pagamento") }

        #expect(screen.payButton.isHidden)
        #expect(!screen.newPaymentButton.isHidden)
        #expect(await server.receivedIdempotencyKeys.count == 1)
        #expect(await server.receivedStatusQueries.count == 1)
        #expect(await server.backend.ledgerEntries.count == 1)
    }

    @Test
    func newPaymentAfterReceiptUsesANewKey() async throws {
        let server = MockPaymentHTTPServer()
        let screen = Screen(server: server)

        screen.tapPay()
        try await waitUntil { screen.status == "Pagamento confirmado: pay_1" }

        screen.newPaymentButton.sendActions(for: .touchUpInside)
        #expect(screen.payButton.isEnabled)

        screen.tapPay()
        try await waitUntil { screen.status == "Pagamento confirmado: pay_2" }

        #expect(Set(await server.receivedIdempotencyKeys).count == 2)
        #expect(await server.backend.ledgerEntries.count == 2)
    }

    @Test
    func rejectionEndsTheIntent() async throws {
        let transport = GatedTransport(failure: PaymentError.rejected(statusCode: 402))
        transport.open()
        let screen = Screen(client: PaymentClient(transport: transport))

        screen.tapPay()
        try await waitUntil { screen.payButton.isEnabled }
        #expect(screen.status == "O servidor recusou o pagamento.")

        screen.tapPay()
        try await waitUntil { transport.requests.count == 2 && screen.payButton.isEnabled }

        let keys = transport.requests.map(\.idempotencyKey)
        #expect(keys[0] != keys[1])
    }
}

/// The controller with its view loaded, plus access to the subviews by accessibility identifier.
@MainActor
private struct Screen {
    let controller: PaymentViewController

    init(client: PaymentClient) {
        controller = PaymentViewController(paymentClient: client)
        controller.loadViewIfNeeded()
    }

    init(server: MockPaymentHTTPServer) {
        let url = URL(string: "https://mock.payments.local/v1")!
        self.init(client: PaymentClient(transport: HTTPPaymentTransport(baseURL: url, httpClient: server)))
    }

    var payButton: UIButton { find("payment.pay") }
    var newPaymentButton: UIButton { find("payment.new") }
    var status: String { (find("payment.status") as UILabel).text ?? "" }

    func tapPay() {
        payButton.sendActions(for: .touchUpInside)
    }

    private func find<View: UIView>(_ identifier: String) -> View {
        func search(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == identifier { return view }
            return view.subviews.lazy.compactMap(search).first
        }
        return search(controller.view) as! View
    }
}

/// Holds every request until `open()`; then answers with a payment or the given failure.
private final class GatedTransport: PaymentTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CreatePaymentRequest] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private let failure: PaymentError?

    init(failure: PaymentError? = nil) {
        self.failure = failure
    }

    var requests: [CreatePaymentRequest] {
        lock.withLock { recorded }
    }

    func open() {
        let resumed = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    func send(_ request: CreatePaymentRequest) async throws -> Payment {
        lock.withLock { recorded.append(request) }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if !isOpen { waiting.append(continuation) }
                return isOpen
            }
            if resumeNow { continuation.resume() }
        }
        if let failure { throw failure }
        return Payment(id: "pay_1", cents: request.body.cents, destinationAccountID: request.body.destinationAccountID)
    }

    func status(idempotencyKey: String) async throws -> PaymentStatus {
        .notFound
    }
}

private struct Timeout: Error {}

@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Timeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
