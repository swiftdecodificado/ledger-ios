import Payments
import UIKit

@MainActor
final class PaymentViewController: UIViewController {
    private var paymentIntent: PaymentIntent?
    private let paymentClient: PaymentClient
    private let paymentView = PaymentView()

    private var payButton: UIButton { paymentView.payButton }

    init(paymentClient: PaymentClient) {
        self.paymentClient = paymentClient
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = paymentView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        payButton.addTarget(self, action: #selector(payTapped), for: .touchUpInside)
        paymentView.newPaymentButton.addTarget(self, action: #selector(newPaymentTapped), for: .touchUpInside)
        paymentView.render(.ready)
    }

    @objc private func payTapped() {
        let intent = paymentIntent ?? PaymentIntent(
            idempotencyKey: UUID().uuidString,
            cents: 12_500,
            destinationAccountID: "account-42"
        )
        let isRecovering = paymentIntent != nil

        paymentIntent = intent
        payButton.isEnabled = false

        Task {
            if isRecovering {
                await recover(intent)
            } else {
                await submit(intent)
            }
        }
    }

    private func submit(_ intent: PaymentIntent) async {
        showSendingState()
        do {
            let payment = try await paymentClient.createPayment(intent)

            showReceipt(payment)
            paymentIntent = nil
        } catch PaymentError.outcomeUnknown {
            showUnknownPaymentState()
            payButton.isEnabled = true
        } catch {
            showRejectedPayment()
            paymentIntent = nil
            payButton.isEnabled = true
        }
    }

    private func recover(_ intent: PaymentIntent) async {
        showCheckingState()
        let status: PaymentStatus
        do {
            status = try await paymentClient.status(of: intent)
        } catch {
            showUnknownPaymentState()
            payButton.isEnabled = true
            return
        }

        switch status {
        case .succeeded(let payment):
            showReceipt(payment)
            paymentIntent = nil
        case .declined:
            showRejectedPayment()
            paymentIntent = nil
            payButton.isEnabled = true
        case .processing:
            showStillProcessingState()
            payButton.isEnabled = true
        case .notFound:
            await submit(intent)
        case .expired:
            showUnableToRecoverState()
        }
    }

    @objc private func newPaymentTapped() {
        paymentIntent = nil
        payButton.isEnabled = true
        paymentView.render(.ready)
    }

    private func showReceipt(_ payment: Payment) {
        paymentView.render(.confirmed(payment))
    }

    private func showSendingState() {
        paymentView.render(.processing(idempotencyKey: paymentIntent?.idempotencyKey ?? ""))
    }

    private func showCheckingState() {
        paymentView.render(.checking(idempotencyKey: paymentIntent?.idempotencyKey ?? ""))
    }

    private func showUnknownPaymentState() {
        paymentView.render(.unknown(idempotencyKey: paymentIntent?.idempotencyKey ?? ""))
    }

    private func showStillProcessingState() {
        paymentView.render(.stillProcessing(idempotencyKey: paymentIntent?.idempotencyKey ?? ""))
    }

    private func showUnableToRecoverState() {
        paymentView.render(.unrecoverable(idempotencyKey: paymentIntent?.idempotencyKey ?? ""))
    }

    private func showRejectedPayment() {
        paymentView.render(.rejected)
    }
}
