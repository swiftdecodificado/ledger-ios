import Foundation
import Testing
import Payments
import PaymentsMockBackend

// The same contract checks against the in-memory server and, when LEDGERCORE_BASE_URL is set,
// against a real backend:
//
//   LEDGERCORE_BASE_URL=http://localhost:8080/v1 swift test --filter PaymentsContractTests
//
// Each test uses fresh UUID keys, so they can run against a shared server.

enum ContractTarget: Sendable, CustomTestStringConvertible {
    case mock
    case live(URL)

    static var all: [ContractTarget] {
        let live = ProcessInfo.processInfo.environment["LEDGERCORE_BASE_URL"]
            .flatMap(URL.init(string:))
            .map { ContractTarget.live($0) }
        return [.mock] + (live.map { [$0] } ?? [])
    }

    var testDescription: String {
        switch self {
        case .mock: "mock"
        case .live(let url): url.absoluteString
        }
    }

    func makeAPI() -> ContractAPI {
        switch self {
        case .mock:
            ContractAPI(baseURL: URL(string: "https://mock.payments.local/v1")!, http: MockPaymentHTTPServer())
        case .live(let url):
            ContractAPI(baseURL: url, http: URLSessionHTTPClient())
        }
    }
}

struct ContractAPI {
    struct Response {
        let status: Int
        let data: Data
        let headers: HTTPURLResponse

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: data)
        }

        var isReplay: Bool {
            headers.value(forHTTPHeaderField: PaymentsAPI.replayedHeader) == "true"
        }
    }

    let baseURL: URL
    let http: any HTTPClient

    func post(key: String?, body: Data) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: PaymentsAPI.paymentsPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: PaymentsAPI.idempotencyKeyHeader)
        request.httpBody = body
        let (data, response) = try await http.data(for: request)
        return Response(status: response.statusCode, data: data, headers: response)
    }

    func post(key: String, cents: Int = 12_500, destination: String = "account-42") async throws -> Response {
        try await post(key: key, body: JSONEncoder().encode(PaymentRequest(cents: cents, destinationAccountID: destination)))
    }

    func attempt(key: String) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: PaymentsAPI.attemptsPath).appending(path: key))
        request.httpMethod = "GET"
        let (data, response) = try await http.data(for: request)
        return Response(status: response.statusCode, data: data, headers: response)
    }

    var client: PaymentClient {
        PaymentClient(transport: HTTPPaymentTransport(baseURL: baseURL, httpClient: http))
    }
}

private func newKey() -> String { UUID().uuidString }

@Test(arguments: ContractTarget.all)
func retryWithTheSameKeyReplaysTheFirstResponse(target: ContractTarget) async throws {
    let api = target.makeAPI()
    let key = newKey()

    let first = try await api.post(key: key)
    let second = try await api.post(key: key)

    #expect(first.status == 201)
    #expect(!first.isReplay)
    #expect(second.status == 201)
    #expect(second.isReplay)
    #expect(try first.decode(Payment.self) == second.decode(Payment.self))
}

@Test(arguments: ContractTarget.all)
func attemptAfterALostResponseShowsThePayment(target: ContractTarget) async throws {
    let api = target.makeAPI()
    let key = newKey()

    // The client never reads this response, as if it had been lost.
    let lost = try await api.post(key: key)
    let attempt = try await api.attempt(key: key)

    #expect(attempt.status == 200)
    let body = try attempt.decode(PaymentAttemptResponse.self)
    #expect(body.status == .succeeded)
    #expect(body.payment == (try lost.decode(Payment.self)))
}

@Test(arguments: ContractTarget.all)
func sameKeyWithAnotherBodyIsRejected(target: ContractTarget) async throws {
    let api = target.makeAPI()
    let key = newKey()
    _ = try await api.post(key: key)

    let reused = try await api.post(key: key, cents: 99_900)

    #expect(reused.status == 422)
    #expect(try reused.decode(APIErrorResponse.self).error.code == "idempotency_key_reused")
}

@Test(arguments: ContractTarget.all)
func unknownKeyHasNoAttempt(target: ContractTarget) async throws {
    let attempt = try await target.makeAPI().attempt(key: newKey())

    #expect(attempt.status == 404)
    #expect(try attempt.decode(APIErrorResponse.self).error.code == "not_found")
}

@Test(arguments: ContractTarget.all)
func postWithoutKeyIsRejected(target: ContractTarget) async throws {
    let body = try JSONEncoder().encode(PaymentRequest(cents: 12_500, destinationAccountID: "account-42"))
    let response = try await target.makeAPI().post(key: nil, body: body)

    #expect(response.status == 400)
    #expect(try response.decode(APIErrorResponse.self).error.code == "missing_idempotency_key")
}

@Test(arguments: ContractTarget.all)
func invalidBodyDoesNotReserveTheKey(target: ContractTarget) async throws {
    let api = target.makeAPI()
    let key = newKey()

    let invalid = try await api.post(key: key, cents: 0)
    let valid = try await api.post(key: key)

    #expect(invalid.status == 400)
    #expect(try invalid.decode(APIErrorResponse.self).error.code == "invalid_body")
    #expect(valid.status == 201)
    #expect(!valid.isReplay)
}

@Test(arguments: ContractTarget.all)
func concurrentRequestsWithTheSameKeyShareOnePayment(target: ContractTarget) async throws {
    let api = target.makeAPI()
    let key = newKey()

    async let first = api.post(key: key)
    async let second = api.post(key: key)
    let responses = try await [first, second]

    #expect(responses.allSatisfy { [201, 409].contains($0.status) })
    let payments = try responses.filter { $0.status == 201 }.map { try $0.decode(Payment.self) }
    #expect(!payments.isEmpty)
    #expect(Set(payments.map(\.id)).count == 1)
}

@Test(arguments: ContractTarget.all)
func clientRecoversThroughTheAttempt(target: ContractTarget) async throws {
    let client = target.makeAPI().client
    let intent = PaymentIntent(idempotencyKey: newKey(), cents: 12_500, destinationAccountID: "account-42")

    #expect(try await client.status(of: intent) == .notFound)
    let payment = try await client.createPayment(intent)
    #expect(try await client.status(of: intent) == .succeeded(payment))
}
