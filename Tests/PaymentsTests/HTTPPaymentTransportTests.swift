import Foundation
import Testing
@testable import Payments

struct StubHTTPClient: HTTPClient {
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try handler(request)
    }

    static func status(_ code: Int, body: String = "{}") -> StubHTTPClient {
        StubHTTPClient { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    static func failing(_ error: any Error) -> StubHTTPClient {
        StubHTTPClient { _ in throw error }
    }
}

private let baseURL = URL(string: "https://payments.example.com/v1")!
private let request = CreatePaymentRequest(
    intent: PaymentIntent(idempotencyKey: "payment-intent-42", cents: 12_500, destinationAccountID: "account-42")
)

@Test
func buildsThePostWithTheKeyInTheHeader() throws {
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: StubHTTPClient.status(201))
    let urlRequest = try transport.makeURLRequest(for: request)

    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.url?.absoluteString == "https://payments.example.com/v1/payments")
    #expect(urlRequest.value(forHTTPHeaderField: "Idempotency-Key") == "payment-intent-42")
    #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try JSONDecoder().decode(PaymentRequest.self, from: try #require(urlRequest.httpBody))
    #expect(body == PaymentRequest(cents: 12_500, destinationAccountID: "account-42"))
}

@Test
func decodesAConfirmedPayment() async throws {
    let json = #"{"id":"pay_1","cents":12500,"destinationAccountID":"account-42"}"#
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: StubHTTPClient.status(201, body: json))

    let payment = try await transport.send(request)

    #expect(payment == Payment(id: "pay_1", cents: 12_500, destinationAccountID: "account-42"))
}

@Test(arguments: [
    (URLError.Code.timedOut, PaymentError.outcomeUnknown),
    (URLError.Code.networkConnectionLost, PaymentError.outcomeUnknown),
    (URLError.Code.notConnectedToInternet, PaymentError.outcomeUnknown),
])
func transportFailuresAreAnUnknownOutcome(code: URLError.Code, expected: PaymentError) async {
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: StubHTTPClient.failing(URLError(code)))

    await #expect(throws: expected) {
        try await transport.send(request)
    }
}

@Test(arguments: [
    (409, PaymentError.outcomeUnknown),
    (410, PaymentError.outcomeUnknown),
    (422, PaymentError.idempotencyKeyReusedWithDifferentRequest),
    (400, PaymentError.rejected(statusCode: 400)),
    (402, PaymentError.rejected(statusCode: 402)),
    (500, PaymentError.outcomeUnknown),
    (503, PaymentError.outcomeUnknown),
])
func statusCodesMapToPaymentErrors(status: Int, expected: PaymentError) async {
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: StubHTTPClient.status(status))

    await #expect(throws: expected) {
        try await transport.send(request)
    }
}

@Test
func unreadableSuccessIsAnUnknownOutcome() async {
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: StubHTTPClient.status(201, body: "ok"))

    await #expect(throws: PaymentError.outcomeUnknown) {
        try await transport.send(request)
    }
}

@Test
func buildsTheStatusQueryWithTheKeyInThePath() {
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: StubHTTPClient.status(200))
    let urlRequest = transport.makeStatusRequest(idempotencyKey: "payment-intent-42")

    #expect(urlRequest.httpMethod == "GET")
    #expect(urlRequest.url?.absoluteString == "https://payments.example.com/v1/payment-attempts/payment-intent-42")
}

@Test(arguments: [
    (200, #"{"status":"processing"}"#, PaymentStatus.processing),
    (
        200,
        #"{"status":"succeeded","payment":{"id":"pay_1","cents":12500,"destinationAccountID":"account-42"}}"#,
        PaymentStatus.succeeded(Payment(id: "pay_1", cents: 12_500, destinationAccountID: "account-42"))
    ),
    (
        200,
        #"{"status":"declined","error":{"code":"amount_exceeds_limit","message":"x"}}"#,
        PaymentStatus.declined(code: "amount_exceeds_limit")
    ),
    (404, #"{"error":{"code":"not_found","message":"x"}}"#, PaymentStatus.notFound),
    (410, #"{"error":{"code":"idempotency_key_expired","message":"x"}}"#, PaymentStatus.expired),
])
func statusResponsesMapToPaymentStatus(code: Int, body: String, expected: PaymentStatus) async throws {
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: StubHTTPClient.status(code, body: body))

    #expect(try await transport.status(idempotencyKey: "payment-intent-42") == expected)
}

@Test(arguments: [
    StubHTTPClient.failing(URLError(.timedOut)),
    StubHTTPClient.status(503),
    StubHTTPClient.status(200, body: #"{"status":"succeeded"}"#),
])
func unusableStatusAnswersAreAnUnknownOutcome(client: StubHTTPClient) async {
    let transport = HTTPPaymentTransport(baseURL: baseURL, httpClient: client)

    await #expect(throws: PaymentError.outcomeUnknown) {
        try await transport.status(idempotencyKey: "payment-intent-42")
    }
}
