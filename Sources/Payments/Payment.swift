/// A payment the server confirmed. A retry with the same key returns the same `id`.
public struct Payment: Codable, Equatable, Sendable {
    public let id: String
    public let cents: Int
    public let destinationAccountID: String

    public init(id: String, cents: Int, destinationAccountID: String) {
        self.id = id
        self.cents = cents
        self.destinationAccountID = destinationAccountID
    }
}
