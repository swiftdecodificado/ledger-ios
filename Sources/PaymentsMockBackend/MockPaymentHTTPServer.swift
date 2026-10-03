import Foundation
import Payments

/// Stands in for the network and the HTTP layer of the backend. It parses the `URLRequest` the way
/// the real server would and answers as described in `openapi.yaml`.
public actor MockPaymentHTTPServer: HTTPClient {
    /// A failure applied to the next `POST /payments`.
    public enum Fault: String, CaseIterable, Sendable {
        /// The server commits, but the response never reaches the client.
        case loseResponse
        /// The server dies after reserving the key and before committing. The connection drops.
        case crashBeforeCommit
        /// The server commits and then answers 500.
        case failAfterCommit
    }

    public struct Snapshot: Equatable, Sendable {
        public let receivedIdempotencyKeys: [String]
        public let receivedStatusQueries: [String]
        public let ledgerEntries: [LedgerEntry]
        public let nextFault: Fault?
    }

    public let backend: MockPaymentBackend
    public private(set) var receivedIdempotencyKeys: [String] = []
    public private(set) var receivedStatusQueries: [String] = []
    public private(set) var nextFault: Fault?

    private let networkDelay: Duration
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public init(backend: MockPaymentBackend = MockPaymentBackend(), networkDelay: Duration = .zero, nextFault: Fault? = nil) {
        self.backend = backend
        self.networkDelay = networkDelay
        self.nextFault = nextFault
    }

    public func setNextFault(_ fault: Fault?) async {
        nextFault = fault
        await publish()
    }

    /// Current state first, then a new value after every change. Used by the app's debug panel.
    public func snapshots() async -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { _ in
            Task { await self.removeObserver(id) }
        }
        continuation.yield(await snapshot())
        return stream
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }

        if networkDelay > .zero {
            try await Task.sleep(for: networkDelay)
        }

        let path = url.pathComponents
        switch (request.httpMethod, path.last, path.dropLast().last) {
        case ("POST", PaymentsAPI.paymentsPath, _):
            return try await createPayment(request, url: url)
        case ("GET", let key?, PaymentsAPI.attemptsPath):
            return await attemptStatus(idempotencyKey: key, url: url)
        default:
            return Self.error("not_found", "Rota inexistente.", status: 404, url: url)
        }
    }

    private func createPayment(_ request: URLRequest, url: URL) async throws -> (Data, HTTPURLResponse) {
        guard
            let key = request.value(forHTTPHeaderField: PaymentsAPI.idempotencyKeyHeader),
            !key.isEmpty, key.count <= 255
        else {
            return Self.error("missing_idempotency_key", "Envie o cabeçalho Idempotency-Key.", status: 400, url: url)
        }
        // Validation errors are not stored: the request never started, so the key stays free.
        guard
            let body = request.httpBody,
            let paymentRequest = try? JSONDecoder().decode(PaymentRequest.self, from: body),
            paymentRequest.cents > 0,
            !paymentRequest.destinationAccountID.isEmpty
        else {
            return Self.error("invalid_body", "Corpo inválido.", status: 400, url: url)
        }

        receivedIdempotencyKeys.append(key)
        let fault = nextFault
        nextFault = nil
        await publish()

        if fault == .crashBeforeCommit {
            await backend.crashBeforeNextCommit()
        }

        let response: (Data, HTTPURLResponse)
        do {
            let result = try await backend.createPayment(request: paymentRequest, idempotencyKey: key)
            response = Self.encode(result, url: url)
        } catch MockPaymentBackend.Failure.idempotencyKeyReusedWithDifferentRequest {
            response = Self.error("idempotency_key_reused", "Chave usada com outro corpo.", status: 422, url: url)
        } catch MockPaymentBackend.Failure.requestInProgress {
            response = Self.error("request_in_progress", "Chave em processamento.", status: 409, url: url)
        } catch MockPaymentBackend.Failure.idempotencyKeyExpired {
            response = Self.expiredKey(url: url)
        } catch {
            await publish()
            throw URLError(.networkConnectionLost)
        }

        await publish()
        switch fault {
        case .loseResponse:
            throw URLError(.timedOut)
        case .failAfterCommit:
            return Self.error("internal_error", "Erro interno.", status: 500, url: url)
        case .crashBeforeCommit, nil:
            return response
        }
    }

    private func attemptStatus(idempotencyKey: String, url: URL) async -> (Data, HTTPURLResponse) {
        receivedStatusQueries.append(idempotencyKey)
        await publish()

        let attempt: PaymentAttemptResponse
        switch await backend.attemptStatus(idempotencyKey: idempotencyKey) {
        case nil:
            return Self.error("not_found", "Nenhuma tentativa com essa chave.", status: 404, url: url)
        case .expired:
            return Self.expiredKey(url: url)
        case .processing:
            attempt = PaymentAttemptResponse(status: .processing)
        case .completed(let result):
            switch result.body {
            case .payment(let payment):
                attempt = PaymentAttemptResponse(status: .succeeded, payment: payment)
            case .error(let error):
                attempt = PaymentAttemptResponse(status: .declined, error: error.error)
            }
        }
        return (Self.encoded(attempt), Self.httpResponse(status: 200, url: url))
    }

    private func snapshot() async -> Snapshot {
        Snapshot(
            receivedIdempotencyKeys: receivedIdempotencyKeys,
            receivedStatusQueries: receivedStatusQueries,
            ledgerEntries: await backend.ledgerEntries,
            nextFault: nextFault
        )
    }

    private func publish() async {
        guard !observers.isEmpty else { return }
        let current = await snapshot()
        for observer in observers.values {
            observer.yield(current)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private static func encode(_ result: PaymentResult, url: URL) -> (Data, HTTPURLResponse) {
        let data = switch result.body {
        case .payment(let payment): encoded(payment)
        case .error(let error): encoded(error)
        }
        let headers = result.isReplay ? [PaymentsAPI.replayedHeader: "true"] : [:]
        return (data, httpResponse(status: result.statusCode, url: url, headers: headers))
    }

    private static func expiredKey(url: URL) -> (Data, HTTPURLResponse) {
        error("idempotency_key_expired", "A chave passou do prazo de retenção.", status: 410, url: url)
    }

    private static func error(_ code: String, _ message: String, status: Int, url: URL) -> (Data, HTTPURLResponse) {
        (encoded(APIErrorResponse(code: code, message: message)), httpResponse(status: status, url: url))
    }

    private static func encoded(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private static func httpResponse(status: Int, url: URL, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "application/json"]) { current, _ in current }
        )!
    }
}
