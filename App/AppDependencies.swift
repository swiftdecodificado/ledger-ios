import Foundation
import Payments
import PaymentsTestSupport

/// Composition root. When `PAYMENTS_BASE_URL` is set (build setting → Info.plist `PaymentsBaseURL`),
/// the app sends the same requests to that server through `URLSession`. Otherwise it uses the
/// in-memory backend, which follows the same contract (`openapi.yaml`).
struct AppDependencies {
    let paymentClient: PaymentClient
    let mockServer: MockPaymentHTTPServer?

    static let mockBaseURL = URL(string: "https://mock.payments.local/v1")!

    static func make(bundle: Bundle = .main, defaults: UserDefaults = .standard) -> AppDependencies {
        if let baseURL = liveBaseURL(in: bundle) {
            return AppDependencies(
                paymentClient: PaymentClient(transport: HTTPPaymentTransport(baseURL: baseURL)),
                mockServer: nil
            )
        }

        let settings = MockSettings(defaults: defaults)
        let server = MockPaymentHTTPServer(
            backend: MockPaymentBackend(
                configuration: .init(processingDelay: settings.delay, processingLease: settings.processingLease)
            ),
            networkDelay: settings.delay,
            nextFault: settings.firstFault
        )
        return AppDependencies(
            paymentClient: PaymentClient(transport: HTTPPaymentTransport(baseURL: mockBaseURL, httpClient: server)),
            mockServer: server
        )
    }

    private static func liveBaseURL(in bundle: Bundle) -> URL? {
        guard
            let value = bundle.object(forInfoDictionaryKey: "PaymentsBaseURL") as? String,
            !value.isEmpty
        else { return nil }
        return URL(string: value)
    }
}

/// Launch arguments read through `UserDefaults`, e.g. `-MockFirstFault none -MockDelayMilliseconds 0`.
/// The defaults reproduce the article: the first response is lost after the server debits.
struct MockSettings {
    let firstFault: MockPaymentHTTPServer.Fault?
    let delay: Duration
    /// Short enough to watch an abandoned reservation expire while using the app.
    let processingLease: TimeInterval

    init(defaults: UserDefaults) {
        // Launch arguments arrive as strings; integer(forKey:) parses them.
        let isSet = { (key: String) in defaults.object(forKey: key) != nil }
        let fault = defaults.string(forKey: "MockFirstFault") ?? MockPaymentHTTPServer.Fault.loseResponse.rawValue
        firstFault = MockPaymentHTTPServer.Fault(rawValue: fault)
        delay = .milliseconds(isSet("MockDelayMilliseconds") ? defaults.integer(forKey: "MockDelayMilliseconds") : 600)
        processingLease = isSet("MockLeaseSeconds") ? defaults.double(forKey: "MockLeaseSeconds") : 5
    }
}
