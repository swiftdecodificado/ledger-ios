// swift-tools-version: 6.0
import PackageDescription

// Payments: the client side of the contract (intent, request, HTTP transport).
// PaymentsMockBackend: an in-memory server that follows the same HTTP contract, used by the app
// until a real backend exists. The app (Ledger.xcodeproj) depends on both through this package.
let package = Package(
    name: "Payments",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Payments", targets: ["Payments"]),
        .library(name: "PaymentsMockBackend", targets: ["PaymentsMockBackend"]),
    ],
    targets: [
        .target(name: "Payments"),
        .target(name: "PaymentsMockBackend", dependencies: ["Payments"]),
        .testTarget(name: "PaymentsTests", dependencies: ["Payments"]),
        .testTarget(name: "PaymentsMockBackendTests", dependencies: ["Payments", "PaymentsMockBackend"]),
        // Runs against the mock and, with LEDGERCORE_BASE_URL set, against a real backend.
        .testTarget(name: "PaymentsContractTests", dependencies: ["Payments", "PaymentsMockBackend"]),
    ]
)
