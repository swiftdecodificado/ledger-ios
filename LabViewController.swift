import PaymentsMockBackend
import UIKit

/// Puts the payment screen and, while there is no real backend, the mock server panel on one screen.
/// `PaymentViewController` does not know the panel exists.
final class LabViewController: UIViewController {
    private let paymentViewController: PaymentViewController
    private let mockServer: MockPaymentHTTPServer?
    private let panel = MockServerPanelView()

    init(paymentViewController: PaymentViewController, mockServer: MockPaymentHTTPServer?) {
        self.paymentViewController = paymentViewController
        self.mockServer = mockServer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        addChild(paymentViewController)
        let paymentView = paymentViewController.view!
        paymentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(paymentView)
        paymentViewController.didMove(toParent: self)

        guard let mockServer else {
            NSLayoutConstraint.activate([
                paymentView.topAnchor.constraint(equalTo: view.topAnchor),
                paymentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                paymentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                paymentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            return
        }

        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            paymentView.topAnchor.constraint(equalTo: view.topAnchor),
            paymentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paymentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paymentView.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -16),

            panel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        panel.faultControl.addAction(
            UIAction { [panel] _ in
                let fault = panel.selectedFault
                Task { await mockServer.setNextFault(fault) }
            },
            for: .valueChanged
        )

        Task { [weak self] in
            for await snapshot in await mockServer.snapshots() {
                guard let self else { return }
                panel.render(snapshot)
            }
        }
    }
}
