import Payments
import UIKit

/// The payment screen. It renders a state; enabling the button is the controller's decision.
final class PaymentView: UIView {
    enum State: Equatable {
        case ready
        case processing(idempotencyKey: String)
        case checking(idempotencyKey: String)
        case unknown(idempotencyKey: String)
        case stillProcessing(idempotencyKey: String)
        case unrecoverable(idempotencyKey: String)
        case confirmed(Payment)
        case rejected
    }

    let payButton = UIButton(configuration: .filled())
    let newPaymentButton = UIButton(configuration: .gray())

    private let titleLabel = UILabel()
    private let amountLabel = UILabel()
    private let destinationLabel = UILabel()
    private let statusLabel = UILabel()
    private let keyLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ state: State) {
        switch state {
        case .ready:
            statusLabel.text = "Confirme para enviar o pagamento."
            showKey(nil)
            setPayTitle("Pagar")
        case .processing(let key):
            statusLabel.text = "Enviando pagamento…"
            showKey(key)
            setPayTitle("Pagar")
        case .checking(let key):
            statusLabel.text = "Verificando o pagamento…"
            showKey(key)
            setPayTitle("Verificar pagamento")
        case .unknown(let key):
            statusLabel.text = "Não foi possível confirmar o pagamento. Ele pode ter sido processado."
            showKey(key)
            setPayTitle("Verificar pagamento")
        case .stillProcessing(let key):
            statusLabel.text = "O pagamento ainda está em processamento."
            showKey(key)
            setPayTitle("Verificar novamente")
        case .unrecoverable(let key):
            statusLabel.text = "Não é mais possível confirmar este pagamento. Confira o extrato antes de pagar de novo."
            showKey(key)
        case .confirmed(let payment):
            statusLabel.text = "Pagamento confirmado: \(payment.id)"
            showKey(nil)
        case .rejected:
            statusLabel.text = "O servidor recusou o pagamento."
            showKey(nil)
            setPayTitle("Pagar")
        }

        switch state {
        case .processing, .checking:
            activityIndicator.startAnimating()
        default:
            activityIndicator.stopAnimating()
        }
        let finished = switch state {
        case .confirmed, .unrecoverable: true
        default: false
        }
        payButton.isHidden = finished
        newPaymentButton.isHidden = !finished
    }

    private func showKey(_ key: String?) {
        keyLabel.text = key.map { "Chave: \($0)" }
        keyLabel.isHidden = key == nil
    }

    private func setPayTitle(_ title: String) {
        payButton.configuration?.title = title
    }

    private func configureHierarchy() {
        backgroundColor = .systemBackground

        let header = UIStackView(arrangedSubviews: [titleLabel, amountLabel, destinationLabel])
        header.axis = .vertical
        header.spacing = 4

        let status = UIStackView(arrangedSubviews: [activityIndicator, statusLabel])
        status.spacing = 8
        status.alignment = .firstBaseline

        let buttons = UIStackView(arrangedSubviews: [payButton, newPaymentButton])
        buttons.axis = .vertical
        buttons.spacing = 12

        let content = UIStackView(arrangedSubviews: [header, status, keyLabel, buttons])
        content.axis = .vertical
        content.spacing = 24
        content.setCustomSpacing(8, after: status)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func configureContent() {
        titleLabel.text = "Pagamento"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        amountLabel.text = Self.formatted(cents: 12_500)
        amountLabel.font = .preferredFont(forTextStyle: .largeTitle)

        destinationLabel.text = "para account-42"
        destinationLabel.textColor = .secondaryLabel
        destinationLabel.font = .preferredFont(forTextStyle: .subheadline)

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.accessibilityIdentifier = "payment.status"

        keyLabel.numberOfLines = 0
        keyLabel.textColor = .secondaryLabel
        keyLabel.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        keyLabel.accessibilityIdentifier = "payment.key"

        activityIndicator.hidesWhenStopped = true

        payButton.accessibilityIdentifier = "payment.pay"
        newPaymentButton.configuration?.title = "Novo pagamento"
        newPaymentButton.accessibilityIdentifier = "payment.new"

        for label in [titleLabel, amountLabel, destinationLabel, statusLabel, keyLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
    }

    private static func formatted(cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "BRL").locale(Locale(identifier: "pt_BR")))
    }
}
