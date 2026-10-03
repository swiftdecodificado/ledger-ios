import Foundation

/// The client side of `openapi.yaml`: `POST {baseURL}/payments` and `GET {baseURL}/payment-attempts/{key}`.
/// The mock backend implements the same contract.
public struct HTTPPaymentTransport: PaymentTransport {
    private let baseURL: URL
    private let httpClient: any HTTPClient
    private let timeout: TimeInterval

    public init(baseURL: URL, httpClient: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.timeout = timeout
    }

    public func send(_ request: CreatePaymentRequest) async throws -> Payment {
        let (data, response) = try await perform(try makeURLRequest(for: request))

        switch response.statusCode {
        case 200..<300:
            guard let payment = try? JSONDecoder().decode(Payment.self, from: data) else {
                throw PaymentError.outcomeUnknown
            }
            return payment
        case 409:
            // The same key is still being processed: the result exists, it just is not known yet.
            throw PaymentError.outcomeUnknown
        case 410:
            // The key is past its retention period: the server neither processes it again nor tells the result.
            throw PaymentError.outcomeUnknown
        case 422:
            throw PaymentError.idempotencyKeyReusedWithDifferentRequest
        case 500...:
            throw PaymentError.outcomeUnknown
        default:
            throw PaymentError.rejected(statusCode: response.statusCode)
        }
    }

    public func status(idempotencyKey: String) async throws -> PaymentStatus {
        let (data, response) = try await perform(makeStatusRequest(idempotencyKey: idempotencyKey))

        switch response.statusCode {
        case 200:
            guard let attempt = try? JSONDecoder().decode(PaymentAttemptResponse.self, from: data) else {
                throw PaymentError.outcomeUnknown
            }
            switch (attempt.status, attempt.payment, attempt.error) {
            case (.processing, _, _):
                return .processing
            case (.succeeded, let payment?, _):
                return .succeeded(payment)
            case (.declined, _, let error?):
                return .declined(code: error.code)
            default:
                throw PaymentError.outcomeUnknown
            }
        case 404:
            return .notFound
        case 410:
            return .expired
        case 500...:
            throw PaymentError.outcomeUnknown
        default:
            throw PaymentError.rejected(statusCode: response.statusCode)
        }
    }

    func makeURLRequest(for request: CreatePaymentRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: PaymentsAPI.paymentsPath), timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.idempotencyKey, forHTTPHeaderField: PaymentsAPI.idempotencyKeyHeader)
        urlRequest.httpBody = try JSONEncoder().encode(request.body)
        return urlRequest
    }

    func makeStatusRequest(idempotencyKey: String) -> URLRequest {
        let url = baseURL.appending(path: PaymentsAPI.attemptsPath).appending(path: idempotencyKey)
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        return urlRequest
    }

    private func perform(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await httpClient.data(for: urlRequest)
        } catch {
            // Without a response the client cannot tell whether the request reached the server.
            throw PaymentError.outcomeUnknown
        }
    }
}
