import XCTest

final class LostResponseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The article's scenario: the first response is lost after the server debits, and the recovery
    /// finds the payment by asking about the key instead of sending another POST.
    @MainActor
    func testRecoveryAfterLostResponseFindsThePayment() {
        let app = launch(firstFault: "loseResponse", delayMilliseconds: 300)

        app.buttons["payment.pay"].tap()
        XCTAssertTrue(app.buttons["Verificar pagamento"].waitForExistence(timeout: 5))
        XCTAssertTrue(label(app, "payment.status").hasPrefix("Não foi possível confirmar o pagamento"))
        XCTAssertEqual(label(app, "mock.ledger"), "Débitos no ledger: 1")

        app.buttons["payment.pay"].tap()
        XCTAssertTrue(app.staticTexts["Pagamento confirmado: pay_1"].waitForExistence(timeout: 5))
        XCTAssertEqual(label(app, "mock.posts"), "POST recebidos: 1, chaves distintas: 1")
        XCTAssertEqual(label(app, "mock.queries"), "Consultas de status: 1")
        XCTAssertEqual(label(app, "mock.ledger"), "Débitos no ledger: 1")
    }

    /// A tap on the disabled button does not reach the action, so it sends no second request.
    @MainActor
    func testSecondTapWhileDisabledSendsNoRequest() {
        let app = launch(firstFault: "none", delayMilliseconds: 1_500)

        let pay = app.buttons["payment.pay"]
        pay.tap()
        XCTAssertFalse(pay.isEnabled)
        pay.tap()

        XCTAssertTrue(app.staticTexts["Pagamento confirmado: pay_1"].waitForExistence(timeout: 8))
        XCTAssertEqual(label(app, "mock.posts"), "POST recebidos: 1, chaves distintas: 1")
        XCTAssertEqual(label(app, "mock.ledger"), "Débitos no ledger: 1")
    }

    /// A new payment is a new intent: new key, new debit.
    @MainActor
    func testNewPaymentGetsANewKey() {
        let app = launch(firstFault: "none", delayMilliseconds: 0)

        app.buttons["payment.pay"].tap()
        XCTAssertTrue(app.staticTexts["Pagamento confirmado: pay_1"].waitForExistence(timeout: 5))

        app.buttons["payment.new"].tap()
        app.buttons["payment.pay"].tap()
        XCTAssertTrue(app.staticTexts["Pagamento confirmado: pay_2"].waitForExistence(timeout: 5))
        XCTAssertEqual(label(app, "mock.posts"), "POST recebidos: 2, chaves distintas: 2")
        XCTAssertEqual(label(app, "mock.ledger"), "Débitos no ledger: 2")
    }

    @MainActor
    private func launch(firstFault: String, delayMilliseconds: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-MockFirstFault", firstFault,
            "-MockDelayMilliseconds", String(delayMilliseconds),
        ]
        app.launch()
        return app
    }

    @MainActor
    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        app.staticTexts[identifier].label
    }
}
