import PaymentsMockBackend
import UIKit

/// What the in-memory server saw. Exists only while there is no real backend.
final class MockServerPanelView: UIView {
    /// Segment order matches `faults`; the first segment is "no fault".
    static let faults: [MockPaymentHTTPServer.Fault?] = [nil, .loseResponse, .crashBeforeCommit]

    let faultControl = UISegmentedControl(items: ["Nenhuma", "Perder resposta", "Queda antes"])

    private let titleLabel = UILabel()
    private let faultLabel = UILabel()
    private let postsLabel = UILabel()
    private let queriesLabel = UILabel()
    private let ledgerLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selectedFault: MockPaymentHTTPServer.Fault? {
        Self.faults[faultControl.selectedSegmentIndex]
    }

    func render(_ snapshot: MockPaymentHTTPServer.Snapshot) {
        postsLabel.text = "POST recebidos: \(snapshot.receivedIdempotencyKeys.count), "
            + "chaves distintas: \(Set(snapshot.receivedIdempotencyKeys).count)"
        queriesLabel.text = "Consultas de status: \(snapshot.receivedStatusQueries.count)"
        ledgerLabel.text = "Débitos no ledger: \(snapshot.ledgerEntries.count)"
        faultControl.selectedSegmentIndex = Self.faults.firstIndex(of: snapshot.nextFault) ?? 0
    }

    private func configure() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)

        titleLabel.text = "Servidor simulado"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        faultLabel.text = "Falha no próximo POST"
        faultControl.accessibilityIdentifier = "mock.fault"
        faultControl.selectedSegmentIndex = 0

        postsLabel.accessibilityIdentifier = "mock.posts"
        queriesLabel.accessibilityIdentifier = "mock.queries"
        ledgerLabel.accessibilityIdentifier = "mock.ledger"

        for label in [faultLabel, postsLabel, queriesLabel, ledgerLabel] {
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.numberOfLines = 0
        }
        for label in [titleLabel, faultLabel, postsLabel, queriesLabel, ledgerLabel] {
            label.adjustsFontForContentSizeCategory = true
        }

        let content = UIStackView(arrangedSubviews: [titleLabel, faultLabel, faultControl, postsLabel, queriesLabel, ledgerLabel])
        content.axis = .vertical
        content.spacing = 8
        content.setCustomSpacing(12, after: faultControl)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
        ])
    }
}
